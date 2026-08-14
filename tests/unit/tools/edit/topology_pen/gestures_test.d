// Module unittests for the Topology Pen (`tools.edit.topology_pen`).
//
// WHITE-BOX by construction: the rigs below drive the tool's own gesture
// handlers and commit steps directly (`meshSrc_`, `history_`,
// `buildEditFactory_`, `buildFromSource`, `trimBorderRunAroundSeed`, ...).
// That is why this module is named INTO the pen's package rather than into
// `tests.unit.*` like the rest of `tests/unit/`: D grants `package`
// visibility by module NAME, so being called `tools.edit.topology_pen.*` is
// exactly what lets these blocks keep reading the tool's internals -- and it
// is also what keeps that grant off every other module in `tools/edit/`.
// The file's location under `tests/unit/` is irrelevant to the compiler; the
// `tests` dub configuration puts it in the build, and the module declaration
// puts it in the package.
//
// Moved out of the tool module VERBATIM by task 0718 (the pen file was
// 19 905 lines, 57% of them these tests). The blocks are in their
// original order with their assertions untouched; the `version (unittest)`
// helpers they call came with them; the import list below is the pen module's
// own, copied so the moved blocks resolve the same names they always did.
//
// Black-box coverage of the same tool lives elsewhere and did not move:
// `tests/test_topopen_*.d` / `tests/test_fixture_topology_pen_*.d`, driven by
// the HTTP runner.
//
// Run with: dub test --config=tests.

module tools.edit.topology_pen.gestures_test;

import tools.edit.topology_pen;

import bindbc.sdl;
import std.json : JSONValue;
import std.math : hypot, SQRT2;

import tool;
import mesh                : Mesh, GpuMesh, MeshCacheKey;
import math               : Vec3, Viewport, projectToWindowFull, closestOnSegment2D,
                             screenPointToRay, closestPointOnSegmentToRay, dot,
                             pointInPolygon2D, rayPlaneIntersect,
                             AimViewport, aimSpace, ModelSpace,
                             screenPointToLocalRay;
import document             : primaryModelSpace;
import shader              : Shader;
import operator            : VectorStack, viewportOf;
import toolpipe.packets    : ConstrainHitPacket, HoverTarget, HoverTargetKind,
                             SubjectPacket, SnapPacket, SnapType;
import toolpipe.pipeline   : g_pipeCtx;
import toolpipe.stage      : TaskCode;
import toolpipe.stages.constrain : ConstrainStage;
import toolpipe.stages.snap : SnapStage;
import toolpipe.guide       : SnapGuide, GuideDrawState, kGuidePrioritySeed;
import constraint           : resolveHoverTarget, topoPenPressPickPx,
                              topoPenSnapAcceptPx, topoPenSnapGatherPx,
                              kTopoPenSnapAuto, closestPointOnMeshes;
import snap                  : backgroundSourcesFull, SnapAdmit;
import tools.edit.smooth_relax : RelaxVec3, RelaxTopology, deriveBoundary, relaxPasses;
import viewcache            : VertexCache, EdgeCache, FaceBoundsCache;
import bvh_pick              : BvhPick;
import command_history      : CommandHistory;
import commands.mesh.vertex_new : MeshVertexNew;
import commands.mesh.session_edit : MeshSessionEdit;
import snapshot              : MeshSnapshot;
import display_sync         : refreshDisplay;
import change_bus            : MeshEditScope;
import params                : Param, IntEnumEntry, wireTagForValue;
import tool_input            : ToolAction, PassThrough, InputPhase, InputButton,
                                InputMod, ResetScope, InputBinding,
                                resolveToolAction, toButton, toMods;
import drag                  : planeDragDelta;
import eventlog               : queryMouse;

import ImGui = d_imgui;
import d_imgui.imgui_h;

// ---------------------------------------------------------------------------
// kTopoPenBindings — exhaustive resolver-grid pin. A single pure,
// camera-free regression guard covering EVERY (button, modifier) combo this
// tool's grid can see — replaces the 7 scattered `resolveGestureSlot` guards
// the pre-Phase-2 classifier used to need (Ctrl+MMB/Shift+MMB/Ctrl+LMB/
// plain-MMB/plain-RMB/Shift+RMB/Shift+Ctrl+RMB), consolidated into ONE table
// so a bad merge that silently drops or misroutes a row is caught here
// rather than by 7 separate best-effort pins. All 12 slots of the grid now
// resolve to their own chord id (task 0499 wired the last two, Ctrl+RMB and
// Shift+Ctrl+MMB); every Alt-held combo resolves to `PassThrough` (Alt is
// hard-blocked by `resolveToolAction` itself, above the table scan — this
// pin also proves that holds for THIS tool's table).
// ---------------------------------------------------------------------------
unittest {
    // The 10 wired slots, each resolving to its own CHORD id (task 0487 —
    // the id names the chord now; which GESTURE it runs is resolved later
    // from the chord's override plus the user's dropdown/flags).
    assert(resolveToolAction(kTopoPenBindings, InputButton.Left, InputMod.None)
        == TopoPenChord.Lmb, "plain LMB");
    assert(resolveToolAction(kTopoPenBindings, InputButton.Left, InputMod.Shift)
        == TopoPenChord.ShiftLmb, "Shift+LMB");
    assert(resolveToolAction(kTopoPenBindings, InputButton.Left, InputMod.Ctrl)
        == TopoPenChord.CtrlLmb, "Ctrl+LMB");
    assert(resolveToolAction(kTopoPenBindings, InputButton.Left, InputMod.Shift | InputMod.Ctrl)
        == TopoPenChord.ShiftCtrlLmb, "Shift+Ctrl+LMB");
    assert(resolveToolAction(kTopoPenBindings, InputButton.Middle, InputMod.None)
        == TopoPenChord.Mmb, "plain MMB");
    assert(resolveToolAction(kTopoPenBindings, InputButton.Middle, InputMod.Shift)
        == TopoPenChord.ShiftMmb, "Shift+MMB");
    assert(resolveToolAction(kTopoPenBindings, InputButton.Middle, InputMod.Ctrl)
        == TopoPenChord.CtrlMmb, "Ctrl+MMB");
    assert(resolveToolAction(kTopoPenBindings, InputButton.Right, InputMod.None)
        == TopoPenChord.Rmb, "plain RMB");
    assert(resolveToolAction(kTopoPenBindings, InputButton.Right, InputMod.Shift)
        == TopoPenChord.ShiftRmb, "Shift+RMB");
    assert(resolveToolAction(kTopoPenBindings, InputButton.Right, InputMod.Shift | InputMod.Ctrl)
        == TopoPenChord.ShiftCtrlRmb, "Shift+Ctrl+RMB");
    // The 2 slots the reference's dispatcher has no case for — WIRED (task
    // 0499) as rows that override nothing, after being measured executing the
    // dropdown's own mode. They used to answer `PassThrough` here.
    assert(resolveToolAction(kTopoPenBindings, InputButton.Right, InputMod.Ctrl)
        == TopoPenChord.CtrlRmb, "Ctrl+RMB");
    assert(resolveToolAction(kTopoPenBindings, InputButton.Middle, InputMod.Shift | InputMod.Ctrl)
        == TopoPenChord.ShiftCtrlMmb, "Shift+Ctrl+MMB");

    // Every chord belongs to the button its own slot names — the mapping the
    // dispatch books a gesture against, taken from the SLOT so a synthetic
    // press with no `button` field still lands on the right one.
    assert(chordButton(TopoPenChord.Lmb)          == InputButton.Left);
    assert(chordButton(TopoPenChord.ShiftCtrlLmb) == InputButton.Left);
    assert(chordButton(TopoPenChord.Mmb)          == InputButton.Middle);
    assert(chordButton(TopoPenChord.CtrlMmb)      == InputButton.Middle);
    assert(chordButton(TopoPenChord.Rmb)          == InputButton.Right);
    assert(chordButton(TopoPenChord.ShiftCtrlRmb) == InputButton.Right);
    assert(chordButton(TopoPenChord.CtrlRmb)      == InputButton.Right);
    assert(chordButton(TopoPenChord.ShiftCtrlMmb) == InputButton.Middle);

    // The override table itself — the measured half stated as assertions, so a
    // future edit that levels the FlagOv distinction away fails here.
    assert(kChordOv[TopoPenChord.Rmb].loop       == FlagOv.ForceOn,
        "plain RMB FORCES the loop flag (measured: the literal-1 store)");
    assert(kChordOv[TopoPenChord.ShiftRmb].loop  == FlagOv.ForceOn,
        "Shift+RMB FORCES the loop flag (measured bit-identical across loop=false/true)");
    assert(kChordOv[TopoPenChord.ShiftLmb].loop  == FlagOv.FromUser,
        "Shift+LMB READS the loop flag (measured: 1 quad vs 3 on one seed)");
    assert(kChordOv[TopoPenChord.Lmb].mode       == ModeOv.FromUser,
        "the base slot never overrides the dropdown");
    assert(kChordOv[TopoPenChord.Rmb].mode       == ModeOv.FromUser,
        "plain RMB runs the DROPDOWN's mode — it is not an absolute move-loop");
    assert(kChordOv[TopoPenChord.ShiftLmb].mode  == ModeOv.Duplicate);
    assert(kChordOv[TopoPenChord.ShiftRmb].mode  == ModeOv.Duplicate);
    assert(kChordOv[TopoPenChord.CtrlLmb].slide  == FlagOv.ForceOn,
        "Ctrl+LMB forces Edge Slide");
    assert(kChordOv[TopoPenChord.Rmb].slide      == FlagOv.FromUser,
        "and Ctrl+RMB was measured NOT forcing slide, so the rule is not 'Ctrl forces slide'");

    // The 2 rows task 0499 wired: they override NOTHING, on all three columns.
    // Stated column by column because each one pins a separate half of the
    // measurement, and each one is a different way to get this wrong:
    //   * mode  — the slot is not "the base slot of its own button" (base MMB
    //             forces Split, base RMB forces the loop);
    //   * loop  — it is not an RMB-family forced loop either;
    //   * slide — the measured "Ctrl+RMB ran a plain move, no slide" is the
    //             very reason `CtrlLmb`'s slide row is NOT generalised to
    //             "Ctrl forces slide". Level this one out and that asymmetry
    //             loses its evidence.
    foreach (c; [TopoPenChord.CtrlRmb, TopoPenChord.ShiftCtrlMmb]) {
        assert(kChordOv[c].mode  == ModeOv.FromUser,
            "an unbound slot runs the DROPDOWN's mode, not its own button's base mode");
        assert(kChordOv[c].loop  == FlagOv.FromUser,
            "an unbound slot does not force the loop flag");
        assert(kChordOv[c].slide == FlagOv.FromUser,
            "an unbound slot does not force Edge Slide (measured on Ctrl+RMB)");
    }

    // Every Alt combo -> PassThrough, on every button, with or without other
    // modifiers held alongside it (Alt is hard-blocked above the table scan,
    // per `resolveToolAction`'s own contract).
    foreach (btn; [InputButton.Left, InputButton.Middle, InputButton.Right]) {
        assert(resolveToolAction(kTopoPenBindings, btn, InputMod.Alt) == PassThrough);
        assert(resolveToolAction(kTopoPenBindings, btn, InputMod.Alt | InputMod.Shift) == PassThrough);
        assert(resolveToolAction(kTopoPenBindings, btn, InputMod.Alt | InputMod.Ctrl) == PassThrough);
        assert(resolveToolAction(kTopoPenBindings, btn, InputMod.Alt | InputMod.Shift | InputMod.Ctrl) == PassThrough);
    }
}

// ---------------------------------------------------------------------------
// buildFromSource — degenerate/wrong-side release is a clean no-op (review
// SHOULD-FIX, doc/topopen_p3_plan.md). `makePolygonFromVerts(autoOrient:
// false)` returns -1 on a collinear/zero-area (Newell-null) vertex order,
// and by the time either CASE-TRI or CASE-QUAD reaches that call the mesh
// has ALREADY been mutated (the new vertex `b`, and CASE-QUAD's own
// source-triangle delete) — so a bare `return` on that -1 used to leave
// the partial mutation committed as the gesture's one undo entry
// (CASE-QUAD: 3 floating edges + a stray vertex; CASE-TRI: a stray
// vertex). Driven directly (private, same-module access — this failure
// path never reaches gpu_/refreshDisplay, so it's safe under a bare
// `dub test` with no GL context) with a `bPos` placed EXACTLY at an
// existing vertex's own position:
//   CASE-TRI:  B == N's position -> [A,B,N] collapses to a doubled line
//              (zero area is an exact geometric fact for 3 points where
//              two coincide, not a float-precision coincidence).
//   CASE-QUAD: B == A's position -> the spliced quad's two triangular
//              lobes (P,A,Q) and (Q,B,P) cancel EXACTLY: SignedArea
//              (Q,B,P) with B==A equals -SignedArea(P,A,Q) by the same
//              "reverse the vertex order negates signed area" identity,
//              regardless of P/A/Q's actual coordinates.
// Both are exact identities (no camera/raycast round-trip involved), so
// the Newell-null rejection triggers deterministically.
unittest {
    import view            : View;
    import editmode        : EditMode;
    import mesh_edit_delta : MeshEditScope;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_          = history;
    t.buildEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                    "mesh.topoPen_build", "Topology Build",
                                                    MeshEditScope.Geometry | MeshEditScope.Marks);

    // --- CASE-TRI: hub A(0) with one bare edge to N(1); release collinear
    // (B placed exactly at N's own position) ---
    {
        Mesh m;
        t.meshSrc_ = () => &m;

        uint a = m.addVertex(Vec3(0, 0, 0));
        uint n = m.addVertex(Vec3(2, 0, 0));
        m.addEdge(a, n);
        m.buildLoops();

        auto before = MeshSnapshot.capture(m);
        t.buildFromSource(cast(int)a, BuildCase.Tri, cast(int)n, -1, -1, -1,
                          Vec3(2, 0, 0));   // == N's own position -> collinear
        auto after = MeshSnapshot.capture(m);

        assert(after.vertices == before.vertices,
            "CASE-TRI degenerate release must not leave a stray vertex");
        assert(after.edges == before.edges,
            "CASE-TRI degenerate release must not add a stray edge");
        assert(after.faces == before.faces,
            "CASE-TRI degenerate release must not add a face");
        assert(!history.canUndo(),
            "CASE-TRI degenerate release must record NO undo entry");
    }

    // --- CASE-QUAD: hub A is the apex of an existing triangle [P,A,Q];
    // release at B == A's own position -> the spliced quad's two lobes
    // cancel exactly (Newell-null) ---
    {
        Mesh m;
        t.meshSrc_ = () => &m;

        uint p = m.addVertex(Vec3(1, 0, 0));
        uint a = m.addVertex(Vec3(0, 1, 0));
        uint q = m.addVertex(Vec3(-1, 0, 0));
        int triFi = m.makePolygonFromVerts([p, a, q], false);
        assert(triFi >= 0, "setup: the source triangle must be valid");

        auto before = MeshSnapshot.capture(m);
        t.buildFromSource(cast(int)a, BuildCase.Quad, -1, cast(int)p, cast(int)q, triFi,
                          Vec3(0, 1, 0));   // == A's own position -> bowtie cancels to zero area
        auto after = MeshSnapshot.capture(m);

        assert(after.vertices == before.vertices,
            "CASE-QUAD degenerate release must not leave a stray vertex");
        assert(after.edges == before.edges,
            "CASE-QUAD degenerate release must not leave floating edges");
        assert(after.faces == before.faces,
            "CASE-QUAD degenerate release must restore the ORIGINAL triangle, not a partial mutation");
        assert(!history.canUndo(),
            "CASE-QUAD degenerate release must record NO undo entry");
    }
}

// ---------------------------------------------------------------------------
// trimBorderRunAroundSeed — the stop predicate's two phrasings are ONE set.
// The trim only ever evaluates a vertex it reached ALONG A BORDER EDGE, so
// that vertex's dart fan is OPEN, and an open fan yields corners+1 edges
// (`VertexEdgeRange` emits the extra open-end edge) against corners faces
// (`VertexFaceRange`):
//
//     vertexValence(v) == polyCount(v) + 1     for every border-reachable v
//
// so "polyCount <= 1" and "valence == 2" are the same test there. Case A
// pins that on representative rigs; case B pins the identity that CAUSES it,
// so a failure localises. Case D pins the ONE phrasing that is NOT
// equivalent: a degree read off the raw `edges[]` array
// (`Mesh.edgeNeighbors`) instead of the dart fan. Face-less edges — which
// this tool creates itself (`BuildCase.Edge`, see `buildFromSource`) — are in
// `edges[]` but own no dart, so a wire spur on a patch corner reads raw
// degree 3 while the fan reads valence 2. Do not "simplify" the stop test
// onto that enumerator; see the comment on `trimBorderRunAroundSeed` itself.
// ---------------------------------------------------------------------------
unittest {
    import std.algorithm : sort;
    import std.math      : cos, sin, PI;

    auto t = new TopologyPenTool();

    static size_t polyCountOf(const ref Mesh m, uint v) {
        size_t n = 0;
        foreach (fi; m.facesAroundVertex(v)) ++n;
        return n;
    }
    static int[] sortedDup(const(int)[] a) { auto b = a.dup; b.sort(); return b; }

    // A parameterised copy of the trim's walk. Case A asserts
    // walkWith(polygon-count) == trimBorderRunAroundSeed(...), which pins
    // this copy to the shipped function so it cannot drift unnoticed.
    static int[] walkWith(Mesh* m, const(int)[] gathered, int seed,
                          bool delegate(uint) stopAt)
    {
        bool[int] inSet;
        foreach (ei; gathered) inSet[ei] = true;
        if ((seed in inSet) is null) return [seed];

        int[] run = [seed];
        bool[int] taken;
        taken[seed] = true;
        foreach (endpoint; [m.edges[seed][0], m.edges[seed][1]]) {
            uint cur  = endpoint;
            int  came = seed;
            while (true) {
                if (stopAt(cur)) break;
                int next = -1;
                foreach (ei; m.edgesAroundVertex(cur)) {
                    immutable int e2 = cast(int) ei;
                    if (e2 == came) continue;
                    if ((e2 in inSet) is null) continue;
                    if ((e2 in taken) !is null) continue;
                    if (!m.isEdgeBorder(cast(uint) e2)) continue;
                    next = e2;
                    break;
                }
                if (next < 0) break;
                taken[next] = true;
                run ~= next;
                auto ep = m.edges[next];
                cur  = (ep[0] == cur) ? ep[1] : ep[0];
                came = next;
            }
        }
        return run;
    }

    // ---- rigs ----------------------------------------------------------
    static void buildGrid(Mesh* m, uint nx, uint ny) {       // nx*ny quads
        foreach (j; 0 .. ny + 1) foreach (i; 0 .. nx + 1)
            m.addVertex(Vec3(cast(float) i, 0, cast(float) j));
        foreach (j; 0 .. ny) foreach (i; 0 .. nx) {
            immutable uint a = j * (nx + 1) + i;
            m.makePolygonFromVerts([a, a + 1, a + nx + 2, a + nx + 1], false);
        }
        m.buildLoops();
    }
    static void buildAnnulus(Mesh* m, uint n) {              // closed band
        foreach (i; 0 .. n) {
            immutable float a = cast(float)(2.0 * PI * i / n);
            m.addVertex(Vec3(cast(float) cos(a), 0, cast(float) sin(a)));
        }
        foreach (i; 0 .. n) {
            immutable float a = cast(float)(2.0 * PI * i / n);
            m.addVertex(Vec3(2.0f * cast(float) cos(a), 0, 2.0f * cast(float) sin(a)));
        }
        foreach (i; 0 .. n) {
            immutable uint i2 = (i + 1) % n;
            m.makePolygonFromVerts([i, i2, n + i2, n + i], false);
        }
        m.buildLoops();
    }
    static void buildFan(Mesh* m, uint n) {                  // open triangle fan
        m.addVertex(Vec3(0, 0, 0));
        foreach (i; 0 .. n + 1) {
            immutable float a = cast(float)(PI * i / n);
            m.addVertex(Vec3(cast(float) cos(a), 0, cast(float) sin(a)));
        }
        foreach (i; 0 .. n) m.makePolygonFromVerts([0u, 1u + i, 2u + i], false);
        m.buildLoops();
    }
    static void buildEll(Mesh* m) {   // 3 of a 2x2 grid's quads: a REFLEX border
        foreach (j; 0 .. 3) foreach (i; 0 .. 3)
            m.addVertex(Vec3(cast(float) i, 0, cast(float) j));
        m.makePolygonFromVerts([0u, 1u, 4u, 3u], false);
        m.makePolygonFromVerts([1u, 2u, 5u, 4u], false);
        m.makePolygonFromVerts([3u, 4u, 7u, 6u], false);
        m.buildLoops();
    }
    static void buildButterfly(Mesh* m) {   // two quads sharing ONE vertex
        foreach (p; [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,0,1), Vec3(0,0,1),
                     Vec3(-1,0,0), Vec3(-1,0,-1), Vec3(0,0,-1)])
            m.addVertex(p);
        m.makePolygonFromVerts([0u, 1u, 2u, 3u], false);
        m.makePolygonFromVerts([0u, 6u, 5u, 4u], false);
        m.buildLoops();
    }

    // ---- cases A + B ---------------------------------------------------
    // `fanIdentity` is false only for the butterfly, whose shared vertex is
    // TWO fans: both enumerators may see one fan or both, but they always
    // see the SAME one, so the equivalence still holds while the
    // valence == polyCount + 1 identity (a single-fan statement) need not.
    void sweep(string rig, Mesh* m, bool fanIdentity) {
        if (fanIdentity)
            foreach (v; 0 .. cast(uint) m.vertices.length) {
                if (!m.isVertexBorder(v)) continue;
                assert(m.vertexValence(v) == cast(uint) polyCountOf(*m, v) + 1,
                    rig ~ ": a border-reachable vertex must have an OPEN dart fan "
                        ~ "(valence == incident-polygon count + 1) — this identity "
                        ~ "is WHY the two stop phrasings coincide");
            }

        t.meshSrc_ = () => m;
        foreach (ei; 0 .. cast(int) m.edges.length) {
            if (!m.isEdgeBorder(cast(uint) ei)) continue;   // the only seeds the trim sees
            auto gathered = m.selectLoopEdges(cast(uint) ei);

            auto shipped = sortedDup(t.trimBorderRunAroundSeed(gathered, ei));
            auto byPoly  = sortedDup(walkWith(m, gathered, ei,
                               (uint v) => polyCountOf(*m, v) <= 1));
            auto byVal   = sortedDup(walkWith(m, gathered, ei,
                               (uint v) => m.vertexValence(v) == 2));

            assert(shipped == byPoly,
                rig ~ ": the shipped trim IS the incident-polygon-count phrasing");
            assert(shipped == byVal,
                rig ~ ": the valence-2 phrasing must select the SAME run — if this "
                    ~ "fires, the two phrasings have been separated and the "
                    ~ "reference behaviour on that shape is UNMEASURED");
        }
    }

    { Mesh m; buildGrid(&m, 3, 3);   sweep("grid3x3",   &m, true);  }
    { Mesh m; buildGrid(&m, 3, 1);   sweep("strip3",    &m, true);  }
    { Mesh m; buildGrid(&m, 1, 1);   sweep("loneQuad",  &m, true);  }
    { Mesh m; buildAnnulus(&m, 8);   sweep("annulus8",  &m, true);  }
    { Mesh m; buildFan(&m, 4);       sweep("triFan4",   &m, true);  }
    { Mesh m; buildEll(&m);          sweep("ellReflex", &m, true);  }
    { Mesh m; buildButterfly(&m);    sweep("butterfly", &m, false); }

    // ---- case D: the ONE phrasing that is NOT equivalent ----------------
    {
        Mesh m;
        foreach (p; [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,0,1), Vec3(0,0,1)])
            m.addVertex(p);
        immutable uint spur = m.addVertex(Vec3(-1, 0, -1));
        m.makePolygonFromVerts([0u, 1u, 2u, 3u], false);
        m.addEdge(0u, spur);            // a BARE edge: in edges[], owns no dart
        m.buildLoops();

        assert(polyCountOf(m, 0u) == 1,
            "the spur is face-less, so the corner still has ONE incident polygon");
        assert(m.vertexValence(0u) == 2,
            "the dart fan cannot see the spur, so the FAN valence is still 2");
        assert(m.edgeNeighbors(0u).length == 3,
            "...but the RAW edges[] degree is 3 — the two phrasings part here");

        immutable int seed = cast(int) m.edgeIndex(0u, 1u);
        assert(seed >= 0 && m.isEdgeBorder(cast(uint) seed));
        auto gathered = m.selectLoopEdges(cast(uint) seed);
        t.meshSrc_ = () => &m;

        auto shipped = sortedDup(t.trimBorderRunAroundSeed(gathered, seed));
        auto byRaw   = sortedDup(walkWith(&m, gathered, seed,
                           (uint v) => m.edgeNeighbors(v).length == 2));

        assert(shipped.length == 1,
            "the shipped predicate stops at BOTH ends of a lone quad's border edge");
        assert(byRaw != shipped,
            "a raw edges[]-degree phrasing selects a DIFFERENT run — do NOT "
            ~ "refactor the stop test onto Mesh.edgeNeighbors");
    }
}

// ---------------------------------------------------------------------------
// applyMoveTargets — the eps no-op guard (P4, doc/topopen_p4_plan.md hard
// requirement #4, carried onto the live-drag path by task 0484): targets
// landing back within eps of the moving set's CURRENT positions (stationary
// grab / all-on-surface no-move) must leave the mesh untouched, leave
// `moveDirty_` false, and — through `recordLiveMove`'s own `moveDirty_`
// gate — record NO undo entry. Driven directly (private, same-module
// access) — the no-op path returns BEFORE the `refreshDisplay`/`gpu_.upload`
// tail, so it's safe under a bare `dub test` with no GL context, mirroring
// the buildFromSource degenerate-release unittest immediately above. (The
// committing/"real move" path — which DOES reach `gpu_.upload` and therefore
// needs a live GL context — is covered end-to-end by the HTTP suite instead:
// test_topopen_move_drag.d / test_topopen_move_undo_redo.d.)
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_         = history;
    t.moveEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                   "mesh.topoPen_move", "Topology Move",
                                                   MeshEditScope.Position);

    Mesh m;
    t.meshSrc_ = () => &m;
    uint a = m.addVertex(Vec3(1, 2, 3));

    // Stationary grab: the target IS the vertex's own position.
    t.moveArmed_ = true;
    t.moveElem_  = MoveElem.Vertex;
    t.moveVerts_ = [a];
    t.moveBase_  = [Vec3(1, 2, 3)];
    t.moveBefore_ = MeshSnapshot.capture(m);

    auto before = MeshSnapshot.capture(m);
    t.applyMoveTargets([Vec3(1, 2, 3)]);
    auto after = MeshSnapshot.capture(m);
    assert(after.vertices == before.vertices, "stationary grab must not move the vertex");
    assert(!t.moveDirty_, "a no-op apply must leave the drag clean");

    t.recordLiveMove();
    assert(!history.canUndo(), "stationary grab must record NO undo entry");
}

// ---------------------------------------------------------------------------
// removeFaceAt — T1 (P5, doc/topopen_p5_remove_plan.md §Testing, DOMINO):
// removing an INTERIOR/shared-edge face must keep the OTHER face
// byte-unchanged and every edge/vertex in place — the strongest
// keepOrphans+keepFloatingEdges proof (default flags would drop the 3
// now-floating edges instead, discriminating). Driven directly (private,
// same-module access; no gpu_/BVH needed — the display tail is guarded off).
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_           = history;
    t.removeEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                     "mesh.topoPen_remove", "Topology Remove",
                                                     MeshEditScope.Geometry);

    Mesh m;
    t.meshSrc_ = () => &m;

    // Two quads sharing edge 1-2: F0=[0,1,2,3], F1=[1,4,5,2].
    m.addVertex(Vec3(0, 0, 0));   // 0
    m.addVertex(Vec3(1, 0, 0));   // 1
    m.addVertex(Vec3(1, 0, 1));   // 2
    m.addVertex(Vec3(0, 0, 1));   // 3
    m.addVertex(Vec3(2, 0, 0));   // 4
    m.addVertex(Vec3(2, 0, 1));   // 5
    m.addFace([0u, 1u, 2u, 3u]);   // F0 = face index 0
    m.addFace([1u, 4u, 5u, 2u]);   // F1 = face index 1
    m.buildLoops();

    assert(m.vertices.length == 6 && m.edges.length == 7 && m.faces.length == 2,
        "setup: pre-state must be the hand-enumerated domino (6v/7e/2f)");

    t.removeFaceAt(0);   // remove F0

    assert(m.faces.length == 1 && m.faces[0] == [1u, 4u, 5u, 2u],
        "F1 must survive byte-unchanged");
    assert(m.edges.length == 7,
        "keepFloatingEdges must preserve every edge, incl. the 3 now-floating ones (01,23,30)");
    assert(m.vertices.length == 6,
        "keepOrphans must preserve every vertex, incl. 0 and 3 now face-unreferenced");
    assert(history.canUndo(), "a real removal must record one undo entry");
}

// ---------------------------------------------------------------------------
// removeFaceAt — T2 (P5, doc/topopen_p5_remove_plan.md §Testing, GRID
// CORNER): removing a CORNER face on a multi-face grid must leave the
// other 3 faces byte-unchanged and the corner's 2 exclusive boundary edges
// surviving as floating edges — confirms Remove leaves every OTHER face
// intact on a mesh bigger than a single pair.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import mesh : makeGridPlane;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_           = history;
    t.removeEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                     "mesh.topoPen_remove", "Topology Remove",
                                                     MeshEditScope.Geometry);

    Mesh m = makeGridPlane(2);   // 2x2 quads: 9 verts, 12 edges, 4 faces
    t.meshSrc_ = () => &m;

    assert(m.vertices.length == 9 && m.edges.length == 12 && m.faces.length == 4,
        "setup: pre-state must be the 2x2 grid");

    auto other1 = m.faces[1].dup;
    auto other2 = m.faces[2].dup;
    auto other3 = m.faces[3].dup;

    t.removeFaceAt(0);   // corner face

    assert(m.faces.length == 3, "exactly one face must be removed");
    assert(m.faces[0] == other1 && m.faces[1] == other2 && m.faces[2] == other3,
        "the other 3 faces must survive byte-unchanged");
    assert(m.edges.length == 12,
        "keepFloatingEdges must preserve all 12 edges, incl. the corner's 2 now-floating ones");
    assert(m.vertices.length == 9, "keepOrphans must preserve every vertex");
    assert(history.canUndo(), "a real removal must record one undo entry");
}

// ---------------------------------------------------------------------------
// removeFaceAt — T3 (P5, doc/topopen_p5_remove_plan.md §Testing, D3): a miss
// (-1) or an out-of-range face index must be a byte-identical no-op — no
// mutation, no undo entry recorded.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_           = history;
    t.removeEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                     "mesh.topoPen_remove", "Topology Remove",
                                                     MeshEditScope.Geometry);

    Mesh m;
    t.meshSrc_ = () => &m;
    uint v0 = m.addVertex(Vec3(0, 0, 0));
    uint v1 = m.addVertex(Vec3(1, 0, 0));
    uint v2 = m.addVertex(Vec3(1, 0, 1));
    m.addFace([v0, v1, v2]);
    m.buildLoops();

    auto before = MeshSnapshot.capture(m);
    t.removeFaceAt(-1);                       // miss
    t.removeFaceAt(cast(int)m.faces.length);  // out-of-range
    auto after = MeshSnapshot.capture(m);

    assert(after.vertices == before.vertices && after.edges == before.edges
        && after.faces == before.faces, "miss/out-of-range must not mutate the mesh");
    assert(!history.canUndo(), "miss/out-of-range must record NO undo entry");
}

// ---------------------------------------------------------------------------
// removeFaceAt — T4 (P5, doc/topopen_p5_remove_plan.md §Testing): a real
// removal must undo back to the exact pre-removal state, including the
// kept orphan edges/vertices and the removed face itself.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_           = history;
    t.removeEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                     "mesh.topoPen_remove", "Topology Remove",
                                                     MeshEditScope.Geometry);

    Mesh m;
    t.meshSrc_ = () => &m;

    m.addVertex(Vec3(0, 0, 0));
    m.addVertex(Vec3(1, 0, 0));
    m.addVertex(Vec3(1, 0, 1));
    m.addVertex(Vec3(0, 0, 1));
    m.addVertex(Vec3(2, 0, 0));
    m.addVertex(Vec3(2, 0, 1));
    m.addFace([0u, 1u, 2u, 3u]);
    m.addFace([1u, 4u, 5u, 2u]);
    m.buildLoops();

    auto before = MeshSnapshot.capture(m);
    t.removeFaceAt(0);
    assert(history.canUndo(), "a real removal must be undoable");
    history.undo();
    auto after = MeshSnapshot.capture(m);

    assert(after.vertices == before.vertices && after.edges == before.edges
        && after.faces == before.faces,
        "undo must restore the exact pre-removal state, incl. the removed face");
}

// ---------------------------------------------------------------------------
// commitAddLoop — T1 (P6, doc/topopen_p6_addloop_plan.md §Testing, "cube belt
// r=0.5"): FULL kernel reuse via `insertEdgeLoops` on the SAME cube + seed
// edge (0-1) as `source/mesh_ops/loop_slice.d`'s own closed-ring unittest —
// Δv=+4/Δe=+8/Δf=+4 (8/12/6 -> 12/20/10), every new vertex at the EXACT
// midpoint of one of the 4 crossed belt edges. Driven directly (private,
// same-module access; `gpu_` stays null so the guarded display tail never
// runs under bare `dub test`, mirroring `applyMoveTargets`/`removeFaceAt`'s own
// unittests above).
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import mesh : makeCube;
    import std.math : abs;
    import std.format : format;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_            = history;
    t.addLoopEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                      "mesh.topoPen_addloop", "Topology Add Loop",
                                                      MeshEditScope.Geometry | MeshEditScope.Marks);

    Mesh m = makeCube();
    t.meshSrc_ = () => &m;

    uint seed = m.edgeIndex(0, 1);
    assert(seed != uint.max, "setup: seed edge 0-1 must exist on the default cube");
    assert(m.vertices.length == 8 && m.edges.length == 12 && m.faces.length == 6,
        "setup: pre-state must be the untouched cube");

    t.commitAddLoop(seed, 0.5f);

    assert(m.vertices.length == 12,
        format("cube belt r=0.5 must add exactly 4 vertices; got %d", m.vertices.length));
    assert(m.edges.length == 20,
        format("cube belt r=0.5 must add exactly 8 edges; got %d", m.edges.length));
    assert(m.faces.length == 10,
        format("cube belt r=0.5 must add exactly 4 faces; got %d", m.faces.length));

    static bool hasVertNear(const ref Mesh mm, float x, float y, float z, float eps = 1e-4f) {
        foreach (v; mm.vertices)
            if (abs(v.x - x) < eps && abs(v.y - y) < eps && abs(v.z - z) < eps) return true;
        return false;
    }
    // Independently-computed midpoints of the 4 crossed belt edges (0-1,
    // 2-3, 6-7, 4-5 — same belt loop_slice.d's own insertEdgeLoops unittest
    // walks), from the cube's OWN hand-known vertex coordinates, never from
    // the tool's own output.
    assert(hasVertNear(m, 0.0f, -0.5f, -0.5f), "midpoint of edge 0-1 must exist at (0,-0.5,-0.5)");
    assert(hasVertNear(m, 0.0f,  0.5f, -0.5f), "midpoint of edge 2-3 must exist at (0,0.5,-0.5)");
    assert(hasVertNear(m, 0.0f,  0.5f,  0.5f), "midpoint of edge 6-7 must exist at (0,0.5,0.5)");
    assert(hasVertNear(m, 0.0f, -0.5f,  0.5f), "midpoint of edge 4-5 must exist at (0,-0.5,0.5)");

    assert(history.canUndo(), "a real Add Loop cut must record one undo entry");
}

// ---------------------------------------------------------------------------
// commitAddLoop — T2 (P6, doc/topopen_p6_addloop_plan.md §Testing, "cube belt
// r=0.25"): the SAME closed ring, cut at an off-center ratio — every new
// vertex must sit at parameter 0.25 FROM ONE END of its own crossed edge
// (the ± resolves the per-face orientation sign-flip the plan documents;
// symmetric only at r=0.5, which T1 above already covers). Independent
// expecteds computed from the belt edges' OWN pre-cut endpoint coordinates
// (captured before the cut), never from the tool's own output.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import mesh : makeCube;
    import std.math : abs;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_            = history;
    t.addLoopEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                      "mesh.topoPen_addloop", "Topology Add Loop",
                                                      MeshEditScope.Geometry | MeshEditScope.Marks);

    Mesh m = makeCube();
    t.meshSrc_ = () => &m;
    uint seed = m.edgeIndex(0, 1);
    assert(seed != uint.max);

    // Belt edges' endpoints, captured BEFORE the cut (independent ground truth).
    Vec3[2][4] belt = [
        [m.vertices[0], m.vertices[1]],
        [m.vertices[2], m.vertices[3]],
        [m.vertices[6], m.vertices[7]],
        [m.vertices[4], m.vertices[5]],
    ];

    t.commitAddLoop(seed, 0.25f);
    assert(m.vertices.length == 12, "r=0.25 must still add exactly 4 vertices");

    static bool near(Vec3 p, Vec3 q, float eps) {
        return abs(p.x - q.x) < eps && abs(p.y - q.y) < eps && abs(p.z - q.z) < eps;
    }
    enum float eps = 1e-4f;
    foreach (i; 8 .. 12) {
        Vec3 v = m.vertices[i];
        bool matched = false;
        foreach (pair; belt) {
            Vec3 lo = pair[0] + (pair[1] - pair[0]) * 0.25f;
            Vec3 hi = pair[0] + (pair[1] - pair[0]) * 0.75f;
            if (near(v, lo, eps) || near(v, hi, eps)) { matched = true; break; }
        }
        assert(matched,
            "each new vertex must sit at param 0.25 (or its 0.75 sign-flip) "
          ~ "from one end of its own crossed belt edge");
    }
}

// ---------------------------------------------------------------------------
// commitAddLoop — T3 (P6, doc/topopen_p6_addloop_plan.md §Testing, "clamp ->
// no-op"): a ratio landing exactly on a vertex (r<=0 or r>=1) must be a
// byte-identical no-op — no mutation, no undo entry — the verbatim
// `MeshAddLoop.evaluate` open-interval guard copied into `commitAddLoop`.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import mesh : makeCube;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_            = history;
    t.addLoopEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                      "mesh.topoPen_addloop", "Topology Add Loop",
                                                      MeshEditScope.Geometry | MeshEditScope.Marks);

    Mesh m = makeCube();
    t.meshSrc_ = () => &m;
    uint seed = m.edgeIndex(0, 1);

    auto before = MeshSnapshot.capture(m);
    t.commitAddLoop(seed, 1.0f);
    t.commitAddLoop(seed, 0.0f);
    auto after = MeshSnapshot.capture(m);

    assert(after.vertices == before.vertices && after.edges == before.edges
        && after.faces == before.faces,
        "an exact-vertex ratio (0 or 1) must be a byte-identical no-op");
    assert(!history.canUndo(), "clamp no-op must record NO undo entry");
}

// ---------------------------------------------------------------------------
// commitAddLoop — T4 (P6, doc/topopen_p6_addloop_plan.md §Testing, "undo
// restores exact"): a real Add Loop cut must undo back to the exact pre-cut
// state.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import mesh : makeCube;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_            = history;
    t.addLoopEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                      "mesh.topoPen_addloop", "Topology Add Loop",
                                                      MeshEditScope.Geometry | MeshEditScope.Marks);

    Mesh m = makeCube();
    t.meshSrc_ = () => &m;
    uint seed = m.edgeIndex(0, 1);

    auto before = MeshSnapshot.capture(m);
    t.commitAddLoop(seed, 0.5f);
    assert(history.canUndo(), "a real Add Loop cut must be undoable");
    history.undo();
    auto after = MeshSnapshot.capture(m);

    assert(after.vertices == before.vertices && after.edges == before.edges
        && after.faces == before.faces,
        "undo must restore the exact pre-cut state");
}

// ---------------------------------------------------------------------------
// Add Loop — T5: ONE UNIFORM SCALAR across every crossed edge
// (doc/tasks/work/0480-topopen-addloop-middle.md). The reference was measured
// applying a single fraction to the whole ring — the cut fractions across the
// crossed edges of one gesture had a spread of exactly 0 — rather than
// re-deriving a fraction per crossed edge from that edge's own projection.
//
// On the cube belt around edge 0-1 all four crossed edges run along X, so a
// uniform scalar puts all four new vertices at the SAME x (a planar loop);
// a per-edge recomputation would let them scatter. Asserting the SPREAD is
// the direct form of the measured claim, and it is immune to the global
// orientation sign-flip T2 documents (which flips all four together).
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import mesh : makeCube;
    import std.algorithm : max, min;
    import std.math : abs;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_            = history;
    t.addLoopEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                      "mesh.topoPen_addloop", "Topology Add Loop",
                                                      MeshEditScope.Geometry | MeshEditScope.Marks);

    Mesh m = makeCube();
    t.meshSrc_ = () => &m;
    uint seed = m.edgeIndex(0, 1);
    assert(seed != uint.max);

    // Deliberately OFF-CENTER: at r=0.5 a per-edge recomputation would
    // coincide with the uniform answer and the test would prove nothing.
    t.commitAddLoop(seed, 0.25f);
    assert(m.vertices.length == 12, "setup: the belt cut must add exactly 4 vertices");

    float xLo = float.max, xHi = -float.max;
    foreach (i; 8 .. 12) {
        xLo = min(xLo, m.vertices[i].x);
        xHi = max(xHi, m.vertices[i].x);
    }
    assert(xHi - xLo < 1e-6f,
        "every crossed edge must be cut at the SAME scalar fraction — the four new belt "
      ~ "vertices must be coplanar in x (measured spread on the reference: 0)");

    // ...and that shared fraction must be the requested one (0.25 of the
    // 1.0-wide cube edge => |x| == 0.25), not some averaged or defaulted value.
    assert(abs(abs(xLo) - 0.25f) < 1e-5f,
        "the shared fraction must be the requested 0.25 (|x| = 0.25 on a unit cube), "
      ~ "up to the ring's global orientation sign-flip");
}

// ---------------------------------------------------------------------------
// commitAddLoop — T7: an OPEN SPAN through the TOOL path, against the frozen
// reference row `grid3x2_edge_third_click_0149`
// (tests/fixtures/topopen_addloop.json; the whole 8-case golden runs against
// the KERNEL in tests/test_topopen_addloop_conformance.d — this is the one
// case driven through the tool's own commit leg, which that test cannot reach
// because `commitAddLoop`/`history_`/`meshSrc_` are private).
//
// A flat 3x2 quad grid seeded on the BORDER edge 0-1: the ring terminates at
// the mesh boundary at both ends, so the measured delta is the OPEN-SPAN
// formula +(N+1) verts / +(2N+1) edges / +N faces with N=2 crossed quads —
// 12/17/6 -> 15/22/8, NOT the closed ring's +2/+4/+2 — and all three crossed
// rails carry the SAME fraction 0.498288683 from their lower-index endpoint.
// Seed 0-1's only incident face is [0,1,5,4], whose dart is (0,1), so the
// kernel's ratio sense already matches the fixture's and the ratio passes
// unflipped.
//
// The undo assert pins OUR invariant, not parity: one Add Loop drag produces
// exactly ONE history entry (`commitAddLoop` brackets the single
// `insertEdgeLoops` in one before/after snapshot pair and records once; the
// motion handler only updates the ratio and never mutates the mesh). What the
// reference does with undo granularity for this gesture is still unmeasured.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import std.math : abs;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_            = history;
    t.addLoopEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                      "mesh.topoPen_addloop", "Topology Add Loop",
                                                      MeshEditScope.Geometry | MeshEditScope.Marks);

    Mesh m;
    static immutable float[3][12] P = [
        [-0.5f,-0.5f,0], [-0.166667f,-0.5f,0], [0.166667f,-0.5f,0], [0.5f,-0.5f,0],
        [-0.5f, 0.0f,0], [-0.166667f, 0.0f,0], [0.166667f, 0.0f,0], [0.5f, 0.0f,0],
        [-0.5f, 0.5f,0], [-0.166667f, 0.5f,0], [0.166667f, 0.5f,0], [0.5f, 0.5f,0],
    ];
    foreach (p; P) m.vertices ~= Vec3(p[0], p[1], p[2]);
    m.addFace([0u,1u,5u,4u]);  m.addFace([1u,2u,6u,5u]);  m.addFace([2u,3u,7u,6u]);
    m.addFace([4u,5u,9u,8u]);  m.addFace([5u,6u,10u,9u]); m.addFace([6u,7u,11u,10u]);
    m.buildLoops();
    t.meshSrc_ = () => &m;

    uint seed = m.edgeIndex(0, 1);
    assert(seed != uint.max);
    assert(m.vertices.length == 12 && m.edges.length == 17 && m.faces.length == 6);

    t.commitAddLoop(seed, 0.498288683f);

    // Open-span delta: +3 verts / +5 edges / +2 faces (N=2), NOT the closed
    // ring's +2/+4/+2.
    assert(m.vertices.length == 15, "open-span Add Loop must add N+1 == 3 vertices");
    assert(m.edges.length    == 22, "open-span Add Loop must add 2N+1 == 5 edges");
    assert(m.faces.length    ==  8, "open-span Add Loop must add N == 2 faces");
    foreach (const f; m.faces) assert(f.length == 4, "every face must stay a quad");

    // One uniform scalar: all three new verts share the reference x, on the
    // three rails y = -0.5 / 0.0 / +0.5.
    enum float X = -0.3339039385318756f;
    bool[3] seen;
    foreach (i; 12 .. 15) {
        assert(abs(m.vertices[i].x - X) < 1e-5f,
            "every crossed rail must be cut at the SAME scalar fraction");
        if (abs(m.vertices[i].y + 0.5f) < 1e-5f) seen[0] = true;
        if (abs(m.vertices[i].y)        < 1e-5f) seen[1] = true;
        if (abs(m.vertices[i].y - 0.5f) < 1e-5f) seen[2] = true;
    }
    assert(seen[0] && seen[1] && seen[2], "all three rails of the open span must be cut");

    // One gesture, ONE undo entry — this pins OUR side of the granularity
    // question; the reference's own answer is still unmeasured.
    assert(history.canUndo(), "an Add Loop cut must be undoable");
    history.undo();
    assert(m.vertices.length == 12 && m.edges.length == 17 && m.faces.length == 6,
        "one undo must restore the exact pre-cut grid");
    assert(!history.canUndo(), "one Add Loop drag must produce exactly ONE undo entry");
}

// ---------------------------------------------------------------------------
// addLoopUp — T6: the "at the Middle" option, driven through the REAL release
// handler (doc/tasks/work/0480-topopen-addloop-middle.md). Armed manually
// (mirroring the sibling direct-call convention), released at a pixel biased
// well off the seed edge's midpoint: with the option ON the cut must land at
// exactly 0.5 of EVERY crossed edge, ignoring the cursor entirely.
//
// This replaces the equivalent pin that used to sit on Split's release
// handler — the option moved modes, the law did not.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import mesh : makeCube;
    import toolpipe.packets : SubjectPacket;
    import std.algorithm : max, min;
    import std.math : abs;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 200, 200);
    auto history = new CommandHistory();
    t.history_            = history;
    t.addLoopEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                      "mesh.topoPen_addloop", "Topology Add Loop",
                                                      MeshEditScope.Geometry | MeshEditScope.Marks);

    Mesh m = makeCube();
    t.meshSrc_ = () => &m;
    uint seed = m.edgeIndex(0, 1);
    assert(seed != uint.max);

    Viewport vp = view.viewport();
    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    // Arm on the seed edge, with the rail in edges[seed][0] -> [1] order (the
    // same order `seedRail` establishes on a real press).
    t.addLoopArmed_ = true;
    t.addLoopSeed_  = cast(int)seed;
    t.seedRailA_    = m.vertices[m.edges[seed][0]];
    t.seedRailB_    = m.vertices[m.edges[seed][1]];
    t.addLoopMiddle_ = true;

    // Release pixel = 0.8 along the rail — nowhere near the midpoint, so an
    // ignored option would resolve ~0.8 (|x| = 0.3) instead of 0.5 (x = 0).
    Vec3 releasePos = t.seedRailA_ + (t.seedRailB_ - t.seedRailA_) * 0.8f;
    ImVec2 rp;
    assert(TopologyPenTool.projectWorldPt(releasePos, vp, rp), "setup: releasePos must project");

    SDL_MouseButtonEvent eUp;
    eUp.button = SDL_BUTTON_MIDDLE;
    eUp.x = cast(int)rp.x; eUp.y = cast(int)rp.y;
    assert(t.addLoopUp(eUp, vts), "addLoopUp must consume the release");

    assert(m.vertices.length == 12, "the option must still cut the full belt (Δv=+4)");
    float xLo = float.max, xHi = -float.max;
    foreach (i; 8 .. 12) {
        xLo = min(xLo, m.vertices[i].x);
        xHi = max(xHi, m.vertices[i].x);
    }
    assert(xHi - xLo < 1e-6f, "`middle` must be the same uniform scalar on every crossed edge");
    assert(abs(xLo) < 1e-5f,
        "`middle` must force the EXACT midpoint (x = 0 on a unit cube belt), ignoring the "
      ~ "release's own 0.8 fraction");
    assert(history.canUndo(), "a real Add Loop cut must record one undo entry");

    // ...and with the option OFF the SAME release follows the cursor again.
    history.undo();
    t.addLoopMiddle_ = false;
    t.addLoopArmed_  = true;
    t.addLoopSeed_   = cast(int)seed;
    assert(t.addLoopUp(eUp, vts), "addLoopUp must consume the second release");
    assert(m.vertices.length == 12, "the OFF path must still cut the full belt");
    float xLo2 = float.max, xHi2 = -float.max;
    foreach (i; 8 .. 12) {
        xLo2 = min(xLo2, m.vertices[i].x);
        xHi2 = max(xHi2, m.vertices[i].x);
    }
    assert(xHi2 - xLo2 < 1e-6f, "the OFF path is uniform across crossed edges too");
    assert(abs(xLo2) > 0.05f,
        "with the option OFF the cut must follow the release cursor, NOT snap to the midpoint");
}

// ---------------------------------------------------------------------------
// continuationNeighbor — T6 (P7, doc/topopen_p7_slide_plan.md §Testing):
// pure adjacency tests, independent of `commitSlide`/the down-handler.
// Valence-2 (one remaining edge) -> the unique neighbor; valence-1
// (grabbed-edge-only) -> -1; valence-3 on BARE EDGES (two remaining edges,
// no face anywhere, so no polygon to continue around) -> -1, still the
// held-fixed open case. The valence>2 WITH a polygon-continuation rail is
// pinned separately below.
// ---------------------------------------------------------------------------
unittest {
    // Chain D-A-B: A's remaining neighbor (excluding B) is D.
    {
        Mesh m;
        uint d = m.addVertex(Vec3(-2, 0, 0));
        uint a = m.addVertex(Vec3(0, 0, 0));
        uint b = m.addVertex(Vec3(2, 0, 0));
        m.addEdge(d, a);
        m.addEdge(a, b);
        assert(TopologyPenTool.continuationNeighbor(&m, a, b) == cast(int)d,
            "valence-2 endpoint must report its unique remaining neighbor");
    }
    // Bare edge A-B only: A has NO remaining edge once B is excluded.
    {
        Mesh m;
        uint a = m.addVertex(Vec3(0, 0, 0));
        uint b = m.addVertex(Vec3(2, 0, 0));
        m.addEdge(a, b);
        assert(TopologyPenTool.continuationNeighbor(&m, a, b) == -1,
            "valence-1 (grabbed-edge-only) endpoint must report -1 (held fixed)");
    }
    // A connects to B (grabbed), plus TWO others (E, F): 2 remaining edges,
    // and NO face anywhere — so there is no polygon whose walk could pick a
    // continuation, and the endpoint stays on the held-fixed open case.
    {
        Mesh m;
        uint a = m.addVertex(Vec3(0, 0, 0));
        uint b = m.addVertex(Vec3(2, 0, 0));
        uint e = m.addVertex(Vec3(0, 2, 0));
        uint f = m.addVertex(Vec3(0, 0, 2));
        m.addEdge(a, b);
        m.addEdge(a, e);
        m.addEdge(a, f);
        assert(TopologyPenTool.continuationNeighbor(&m, a, b) == -1,
            "valence>2 with NO incident face (no polygon to continue around) must report -1 "
          ~ "(held fixed — never guessed among ambiguous candidates)");
    }
}

// ---------------------------------------------------------------------------
// continuationNeighbor — VALENCE>2 POLYGON-CONTINUATION RAIL (the measured
// rule; supersedes V1's blanket hold-fixed for valence>2).
//
// Rig: quad [0,1,2,3] plus triangle [0,3,4] sharing edge 0-3 — the capture
// rig. Grab edge 0-1. Endpoint v0 is valence-3, so after excluding v1 it has
// TWO candidate neighbours in genuinely different directions (v3 along
// +Z, v4 along -X+Z) and V1 held it FIXED. The grabbed edge 0-1 belongs to
// exactly ONE polygon (the quad), whose walk continues across v0 onto 0-3, so
// v0 must now resolve to v3. v1 (valence-2) is the built-in control: its
// unique remaining neighbour v2, unchanged.
//
// This rig is the SINGLE-candidate case: `continuationRailCandidates` yields
// exactly one, so there is nothing to select and the answer cannot depend on
// the drag. That is asserted structurally below. It is NOT evidence that
// selection among SEVERAL candidates is drag-independent — that claim was
// made when this rule landed and has since been refuted; see
// `continuationNeighbor`'s doc comment.
// ---------------------------------------------------------------------------
unittest {
    Mesh m;
    uint v0 = m.addVertex(Vec3( 0, 0, 0));
    uint v1 = m.addVertex(Vec3( 1, 0, 0));
    uint v2 = m.addVertex(Vec3( 1, 0, 1));
    uint v3 = m.addVertex(Vec3( 0, 0, 1));
    uint v4 = m.addVertex(Vec3(-1, 0, 1));
    m.addFace([v0, v1, v2, v3]);
    m.addFace([v0, v3, v4]);

    assert(m.edgeNeighbors(v0).length == 3, "setup: v0 must be valence-3");

    assert(TopologyPenTool.continuationNeighbor(&m, v0, v1) == cast(int)v3,
        "a valence>2 endpoint must take the POLYGON-CONTINUATION rail (0->3, the edge "
      ~ "continuing the grabbed edge around its own polygon), not be held fixed");
    assert(TopologyPenTool.continuationNeighbor(&m, v1, v0) == cast(int)v2,
        "the valence-2 control endpoint must keep reporting its unique remaining neighbour");

    // Scoped structural check: with exactly ONE candidate there is nothing to
    // select, and `continuationNeighbor` takes no cursor/drag argument at all,
    // so re-querying can only ever return the same rail. Asserted here so a
    // future refactor that threads a direction into the SINGLE-candidate path
    // trips this test. (The multi-candidate path is a different question and
    // is deliberately not answered — see the OPEN-CASE test below.)
    assert(TopologyPenTool.continuationRailCandidates(&m, v0, v1).length == 1,
        "setup: this rig's valence>2 endpoint must offer exactly ONE continuation "
      ~ "candidate — the unambiguous case, which is all this rule acts on");
    assert(TopologyPenTool.continuationNeighbor(&m, v0, v1) == cast(int)v3,
        "a single-candidate rail is unambiguous and cannot depend on the drag");
}

// ---------------------------------------------------------------------------
// continuationNeighbor — OPEN CASE, still held fixed: an INTERIOR grabbed
// edge (two incident faces) offers TWO distinct continuation rails at each
// endpoint, one per face. Measurement says the reference DOES pick one and
// that the pick flips with the sign of the drag's dominant component — a
// SIGN-DEPENDENT selection rule that is not determined (the one candidate law
// that fits all four captured multi-candidate gestures carries the opposite
// sign convention from the 32/32 single-candidate law, so it cannot be the
// same rule). Deferred, NOT tie-broken — this test pins the deferral so a
// later "just pick the first face" shortcut, or a guessed sign rule, cannot
// slip in unnoticed. Rig: quads [0,1,2,3] and [1,4,5,2] sharing edge 1-2.
// ---------------------------------------------------------------------------
unittest {
    Mesh m;
    uint v0 = m.addVertex(Vec3(0, 0, 0));
    uint v1 = m.addVertex(Vec3(1, 0, 0));
    uint v2 = m.addVertex(Vec3(1, 0, 1));
    uint v3 = m.addVertex(Vec3(0, 0, 1));
    uint v4 = m.addVertex(Vec3(2, 0, 0));
    uint v5 = m.addVertex(Vec3(2, 0, 1));
    m.addFace([v0, v1, v2, v3]);
    m.addFace([v1, v4, v5, v2]);

    assert(TopologyPenTool.continuationRailCandidates(&m, v1, v2).length == 2,
        "setup: an interior grabbed edge must offer one continuation per incident face");
    assert(TopologyPenTool.continuationNeighbor(&m, v1, v2) == -1,
        "2+ distinct continuation rails is an OPEN case -> held fixed, never tie-broken");
    assert(TopologyPenTool.continuationNeighbor(&m, v2, v1) == -1,
        "...at both endpoints of the interior edge");

    // The boundary edges of the same rig stay on the valence-2 fast path,
    // proving the new branch didn't disturb the unchanged regime.
    assert(TopologyPenTool.continuationNeighbor(&m, v0, v1) == cast(int)v3,
        "a valence-2 endpoint must still report its unique remaining neighbour");
}

// ---------------------------------------------------------------------------
// commitSlide — the valence>2 endpoint MOVES (end-to-end over the kernel, not
// just the rail lookup). Same capture rig as above: v0 was once held fixed at
// its original position for every fraction; it must travel along the 0->3
// continuation rail, and land nowhere near the competing 0->4 neighbour.
//
// UPDATED for the measured law. `commitSlide` now takes the law's ONE signed
// scalar instead of a per-endpoint `[0,1]` fraction pair. `deltaK = -0.5`
// gives `offset = +0.5 * unit(rail)` at BOTH endpoints; the 0->3 rail is unit
// length, so v0's landing point is numerically the same `p0 + (p3-p0)*0.5` the
// old `tA = 0.5` produced — the rail-CHOICE assertions this test exists for
// are unchanged. What did change: v1 no longer has an independent `tB = 0`, so
// it slides too (its own 1->2 rail, same scalar). That is the law, not a
// weakening — the old "stays put at fraction 0" line is replaced by an
// assertion that v1 lands exactly on ITS own rail, which is a strictly
// stronger statement about the same vertex.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_          = history;
    t.slideEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                    "mesh.topoPen_slide", "Topology Slide",
                                                    MeshEditScope.Position);

    Mesh m;
    t.meshSrc_ = () => &m;
    Vec3 p0 = Vec3( 0, 0, 0), p3 = Vec3(0, 0, 1), p4 = Vec3(-1, 0, 1);
    uint v0 = m.addVertex(p0);
    uint v1 = m.addVertex(Vec3(1, 0, 0));
    uint v2 = m.addVertex(Vec3(1, 0, 1));
    uint v3 = m.addVertex(p3);
    uint v4 = m.addVertex(p4);
    m.addFace([v0, v1, v2, v3]);
    m.addFace([v0, v3, v4]);
    Vec3 p1 = m.vertices[v1], p2 = m.vertices[v2];

    uint seed = m.edgeIndex(v0, v1);
    assert(seed != uint.max, "setup: the grabbed edge 0-1 must exist");

    int nA = TopologyPenTool.continuationNeighbor(&m, v0, v1);
    int nB = TopologyPenTool.continuationNeighbor(&m, v1, v0);
    t.commitSlide(seed, cast(int)v0, cast(int)v1, nA, nB, -0.5f);

    assert((m.vertices[v0] - p0).length > 1e-3f,
        "the valence>2 endpoint must no longer be held fixed");
    assert((m.vertices[v0] - (p0 + (p3 - p0) * 0.5f)).length < 1e-5f,
        "it must land ON the 0->3 polygon-continuation rail, 0.5 world units along it");
    assert((m.vertices[v0] - (p0 + (p4 - p0) * 0.5f)).length > 1e-2f,
        "and NOT on the competing 0->4 rail");
    assert((m.vertices[v1] - (p1 + (p2 - p1) * 0.5f)).length < 1e-5f,
        "the valence-2 control endpoint slides the SAME 0.5 world units along ITS "
      ~ "own 1->2 rail — one scalar, two rail directions");
    assert(m.faces.length == 2 && m.vertices.length == 5,
        "slide is position-only — topology must be untouched");
    assert(history.canUndo(), "a real slide must record one undo entry");
    history.undo();
    assert((m.vertices[v0] - p0).length < 1e-6f, "undo must restore the pre-slide position");
}

// ---------------------------------------------------------------------------
// commitSlide — T1 (P7, doc/topopen_p7_slide_plan.md §Testing, "colinear
// (two-sided)"): a rig where the grabbed edge A-B has A also on edge A-D and
// B also on edge B-E (both valence-2, DIFFERENT rail directions, and
// DIFFERENT rail LENGTHS: |AD| = 2, |BE| = sqrt(18)) — each endpoint must land
// on ITS OWN incident edge, regardless of the other endpoint's rail. Driven
// directly (private, same-module access); `gpu_` stays null so the guarded
// display tail never runs under bare `dub test`, mirroring every other Tier-B
// unittest in this file.
//
// UPDATED for the measured law, with the test's POINT strengthened rather
// than weakened. The old version fed independent fractions (0.4, 0.7) and
// asserted two independent lerps — which under the old law could be satisfied
// by any per-endpoint parameterisation. The law says both endpoints share ONE
// signed scalar and differ only in rail direction, so this now feeds one
// scalar and asserts the consequence the old form could not see: the two
// endpoints travel the SAME world DISTANCE (|deltaK|) along rails of
// DIFFERENT length, i.e. the displacement is a world offset and emphatically
// NOT a shared normalised fraction. Rail INDEPENDENCE, the original point, is
// still asserted — each landing point is checked against its own rail.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_          = history;
    t.slideEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                    "mesh.topoPen_slide", "Topology Slide",
                                                    MeshEditScope.Position);

    Mesh m;
    t.meshSrc_ = () => &m;

    Vec3 a0 = Vec3(0, 0, 0),  d0 = Vec3(-2, 0, 0);
    Vec3 b0 = Vec3(2, 0, 0),  e0 = Vec3(5, 3, 0);
    uint a = m.addVertex(a0);
    uint d = m.addVertex(d0);
    uint b = m.addVertex(b0);
    uint e = m.addVertex(e0);
    m.addEdge(a, d);
    m.addEdge(a, b);
    m.addEdge(b, e);
    uint seed = m.edgeIndex(a, b);
    assert(seed != uint.max, "setup: the grabbed edge A-B must exist");

    assert(TopologyPenTool.continuationNeighbor(&m, a, b) == cast(int)d);
    assert(TopologyPenTool.continuationNeighbor(&m, b, a) == cast(int)e);

    enum float kDeltaK = -0.8f;   // negative -> both endpoints move TOWARD their rail neighbour
    t.commitSlide(seed, cast(int)a, cast(int)b, cast(int)d, cast(int)e, kDeltaK);

    Vec3 railA = (d0 - a0) * (1.0f / (d0 - a0).length);
    Vec3 railB = (e0 - b0) * (1.0f / (e0 - b0).length);
    Vec3 expectedA = a0 + railA * (-kDeltaK);
    Vec3 expectedB = b0 + railB * (-kDeltaK);
    assert((m.vertices[a] - expectedA).length < 1e-5f,
        "A must slide 0.8 WORLD UNITS toward D along A's own incident edge");
    assert((m.vertices[b] - expectedB).length < 1e-5f,
        "B must slide 0.8 WORLD UNITS toward E along B's own incident edge, "
      ~ "independent of A's own rail direction");
    assert(((m.vertices[a] - a0).length - (m.vertices[b] - b0).length) < 1e-5f
        && ((m.vertices[b] - b0).length - (m.vertices[a] - a0).length) < 1e-5f,
        "both endpoints must travel the SAME world distance despite rails of "
      ~ "different length — one shared scalar, not a shared [0,1] fraction");
    assert(history.canUndo(), "a real slide must record one undo entry");
}

// ---------------------------------------------------------------------------
// commitSlide — T2, INVERTED BY MEASUREMENT: NO OVERSHOOT CLAMP.
//
// This test used to assert the opposite — that an overshoot fraction clamps
// EXACTLY to the neighbour's pre-slide position — on the strength of an
// early reading of the reference (plan §1/§3). The conformance capture
// refutes it directly: the reference's slide parameter was measured over
// [-8.53, +4.19] and vertices pass THROUGH the rail neighbour and keep going.
// So the assertion is reversed, not relaxed: the endpoint must land at the
// exact unbounded position, strictly PAST the neighbour, and the old
// clamped-at-neighbour answer is now explicitly asserted WRONG. It is also
// checked in the negative direction (a vertex may run backwards past its own
// start), which the clamped implementation could never do at all.
//
// This is the assertion that makes the gain matter — see
// `slideDeltaFromDrag`'s note on clamp removal.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_          = history;
    t.slideEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                    "mesh.topoPen_slide", "Topology Slide",
                                                    MeshEditScope.Position);

    Mesh m;
    t.meshSrc_ = () => &m;

    Vec3 a0 = Vec3(0, 0, 0), d0 = Vec3(-3, 1, 0);
    uint a = m.addVertex(a0);
    uint d = m.addVertex(d0);
    uint b = m.addVertex(Vec3(2, 0, 0));
    m.addEdge(a, d);
    m.addEdge(a, b);
    uint seed = m.edgeIndex(a, b);

    // |A->D| = sqrt(10) ~= 3.1623. Slide 5 world units toward D: comfortably
    // PAST D, which the old [0,1] clamp made unreachable.
    Vec3 rail = (d0 - a0) * (1.0f / (d0 - a0).length);
    t.commitSlide(seed, cast(int)a, cast(int)b, cast(int)d, -1, -5.0f);

    assert((m.vertices[a] - (a0 + rail * 5.0f)).length < 1e-5f,
        "an overshoot must land at the exact UNBOUNDED position — there is no [0,1] clamp");
    assert((m.vertices[a] - d0).length > 1.0f,
        "...and specifically must NOT stop at the neighbour's pre-slide position");
    assert(dot(m.vertices[a] - d0, d0 - a0) > 0.0f,
        "...it must be BEYOND the neighbour, on the far side");

    // The negative direction is equally unbounded: the vertex runs backwards
    // past its own start, away from the rail neighbour.
    history.undo();
    t.commitSlide(seed, cast(int)a, cast(int)b, cast(int)d, -1, 2.0f);
    assert((m.vertices[a] - (a0 - rail * 2.0f)).length < 1e-5f,
        "a negative slide must run AWAY from the rail neighbour, past the start point");
}

// ---------------------------------------------------------------------------
// commitSlide — T3 (P7, doc/topopen_p7_slide_plan.md §Testing, "topology
// delta = 0"): a real slide must never change vertex/edge/face COUNTS —
// position-only, zero topology mutation.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_          = history;
    t.slideEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                    "mesh.topoPen_slide", "Topology Slide",
                                                    MeshEditScope.Position);

    Mesh m;
    t.meshSrc_ = () => &m;
    uint a = m.addVertex(Vec3(0, 0, 0));
    uint d = m.addVertex(Vec3(-2, 0, 0));
    uint b = m.addVertex(Vec3(2, 0, 0));
    m.addEdge(a, d);
    m.addEdge(a, b);
    uint seed = m.edgeIndex(a, b);

    size_t vBefore = m.vertices.length, eBefore = m.edges.length, fBefore = m.faces.length;
    t.commitSlide(seed, cast(int)a, cast(int)b, cast(int)d, -1, -0.5f);

    assert(m.vertices.length == vBefore, "Slide must never add/remove vertices");
    assert(m.edges.length == eBefore, "Slide must never add/remove edges");
    assert(m.faces.length == fBefore, "Slide must never add/remove faces");
}

// ---------------------------------------------------------------------------
// commitSlide — T4 (P7, doc/topopen_p7_slide_plan.md §Testing,
// "slide-then-undo"): a real slide must undo back to the exact pre-slide
// state.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_          = history;
    t.slideEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                    "mesh.topoPen_slide", "Topology Slide",
                                                    MeshEditScope.Position);

    Mesh m;
    t.meshSrc_ = () => &m;
    uint a = m.addVertex(Vec3(0, 0, 0));
    uint d = m.addVertex(Vec3(-2, 0, 0));
    uint b = m.addVertex(Vec3(2, 0, 0));
    m.addEdge(a, d);
    m.addEdge(a, b);
    uint seed = m.edgeIndex(a, b);

    auto before = MeshSnapshot.capture(m);
    t.commitSlide(seed, cast(int)a, cast(int)b, cast(int)d, -1, -0.5f);
    assert(history.canUndo(), "a real slide must be undoable");
    history.undo();
    auto after = MeshSnapshot.capture(m);

    assert(after.vertices == before.vertices && after.edges == before.edges
        && after.faces == before.faces,
        "undo must restore the exact pre-slide state");
}

// ---------------------------------------------------------------------------
// commitSlide — T5a (P7, doc/topopen_p7_slide_plan.md §Testing, "held-fixed
// endpoint"): B is valence-1 (only the grabbed edge A-B) -> nB=-1 -> B must
// stay UNTOUCHED while A (valence-2, via A-D) slides normally.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_          = history;
    t.slideEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                    "mesh.topoPen_slide", "Topology Slide",
                                                    MeshEditScope.Position);

    Mesh m;
    t.meshSrc_ = () => &m;
    Vec3 a0 = Vec3(0, 0, 0), d0 = Vec3(-2, 0, 0), b0 = Vec3(2, 0, 0);
    uint a = m.addVertex(a0);
    uint d = m.addVertex(d0);
    uint b = m.addVertex(b0);
    m.addEdge(a, d);
    m.addEdge(a, b);   // B's ONLY edge -> valence-1 once A-B itself is grabbed
    uint seed = m.edgeIndex(a, b);

    assert(TopologyPenTool.continuationNeighbor(&m, b, a) == -1,
        "setup: B must have no remaining incident edge once A-B is excluded");

    t.commitSlide(seed, cast(int)a, cast(int)b, cast(int)d, -1, -1.0f);

    // deltaK = -1.0 on the unit-length-per-world-unit rail A->D (|AD| = 2)
    // puts A exactly 1 world unit toward D — numerically the same point the
    // old `tA = 0.5` fraction produced, so this assertion is unchanged.
    Vec3 expectedA = a0 + (d0 - a0) * 0.5f;
    assert((m.vertices[a] - expectedA).length < 1e-5f, "A (slidable) must slide normally");
    assert((m.vertices[b] - b0).length < 1e-6f,
        "B (valence-1, held fixed) must NOT move — a held-fixed endpoint consumes "
      ~ "no scalar at all, even though the scalar is now shared");
}

// ---------------------------------------------------------------------------
// commitSlide — T5b MIXED VALENCE (P7, doc/topopen_p7_slide_plan.md
// §Testing "held-fixed endpoint" + the mixed-valence requirement): B has
// TWO remaining incident edges after excluding the grabbed edge A-B
// (valence-3 overall) and NO incident face -> nB=-1 -> HELD FIXED, while A
// (valence-2) slides normally in the SAME gesture. Distinct from T5a (which
// uses a valence-1 B) — this is the genuinely ambiguous ≥2-remaining case
// with no polygon-continuation rail to resolve it, still deferred rather
// than guessed.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_          = history;
    t.slideEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                    "mesh.topoPen_slide", "Topology Slide",
                                                    MeshEditScope.Position);

    Mesh m;
    t.meshSrc_ = () => &m;
    Vec3 a0 = Vec3(0, 0, 0), d0 = Vec3(-2, 0, 0), b0 = Vec3(2, 0, 0);
    uint a = m.addVertex(a0);
    uint d = m.addVertex(d0);
    uint b = m.addVertex(b0);
    uint g = m.addVertex(Vec3(2, 2, 0));   // B's 2nd extra neighbor
    uint h = m.addVertex(Vec3(2, 0, 2));   // B's 3rd extra neighbor
    m.addEdge(a, d);
    m.addEdge(a, b);   // the edge to be grabbed
    m.addEdge(b, g);
    m.addEdge(b, h);   // B now has 3 total incident edges (valence-3)
    uint seed = m.edgeIndex(a, b);

    assert(TopologyPenTool.continuationNeighbor(&m, a, b) == cast(int)d,
        "setup: A must remain the unambiguous valence-2 endpoint");
    assert(TopologyPenTool.continuationNeighbor(&m, b, a) == -1,
        "setup: B must have 2 remaining incident edges (valence>2) and no face "
      ~ "-> no continuation rail -> deferred/held-fixed");

    t.commitSlide(seed, cast(int)a, cast(int)b, cast(int)d, -1, -1.2f);

    // deltaK = -1.2 on the |AD| = 2 rail lands A at the same point the old
    // `tA = 0.6` fraction produced — assertion unchanged.
    Vec3 expectedA = a0 + (d0 - a0) * 0.6f;
    assert((m.vertices[a] - expectedA).length < 1e-5f,
        "the valence-2 endpoint (A) must slide normally");
    assert((m.vertices[b] - b0).length < 1e-6f,
        "the valence>2 endpoint (B) must be HELD FIXED — never guessed among its "
      ~ "2 remaining incident edges");
    assert(history.canUndo(), "a mixed-valence slide (one endpoint moves) must still be undoable");
}

// ---------------------------------------------------------------------------
// commitSlide — T5c (P7, doc/topopen_p7_slide_plan.md §Testing): BOTH
// endpoints held fixed (an isolated grabbed edge, neither end has any other
// incident edge) must be a byte-identical no-op — no mutation, no undo
// entry.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_          = history;
    t.slideEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                    "mesh.topoPen_slide", "Topology Slide",
                                                    MeshEditScope.Position);

    Mesh m;
    t.meshSrc_ = () => &m;
    uint a = m.addVertex(Vec3(0, 0, 0));
    uint b = m.addVertex(Vec3(2, 0, 0));
    m.addEdge(a, b);   // isolated bare edge -> both endpoints valence-1
    uint seed = m.edgeIndex(a, b);

    assert(TopologyPenTool.continuationNeighbor(&m, a, b) == -1);
    assert(TopologyPenTool.continuationNeighbor(&m, b, a) == -1);

    auto before = MeshSnapshot.capture(m);
    t.commitSlide(seed, cast(int)a, cast(int)b, -1, -1, -0.5f);
    auto after = MeshSnapshot.capture(m);

    assert(after.vertices == before.vertices, "both-fixed slide must not move any vertex");
    assert(!history.canUndo(), "both-fixed slide must record NO undo entry");
}

// ---------------------------------------------------------------------------
// onMouseButtonUp — MIN-DRAG (P7 REV1 FIX-2, doc/topopen_p7_slide_plan.md):
// a Ctrl+LMB release within `kMinDragPx` of the press pixel is a clean
// no-op — no vertex write, no undo entry — driven through the extracted
// `slideUp` release-side helper directly (arming state set up directly,
// mirroring `onCtrlLmbDown`'s post-classification result, rather than
// driving a full screen-space press) so the min-drag GATE ITSELF is under
// test, not just `commitSlide`'s own (also-present) eps guard. Phase-2
// input-dispatch migration (doc/topopen_input_dispatch_phase2_plan.md,
// Testing Category C): calls `slideUp` directly rather than
// `onMouseButtonUp` — the flipped `onMouseButtonUp` now routes through
// `dispatchInput`, which keys on the BASE's private `armed_[button]` (only
// set by a real Down through `onMouseButtonDown`), not on `slideArmed_` this
// test sets directly, so driving `onMouseButtonUp` here would no longer
// reach the min-drag gate at all. `gpu_` stays null and the release event
// carries no `SubjectPacket`, so this never reaches `refreshDisplay` — safe
// under bare `dub test`.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import operator : VectorStack;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_          = history;
    t.slideEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                    "mesh.topoPen_slide", "Topology Slide",
                                                    MeshEditScope.Position);

    Mesh m;
    t.meshSrc_ = () => &m;
    uint a = m.addVertex(Vec3(0, 0, 0));
    uint d = m.addVertex(Vec3(-2, 0, 0));
    uint b = m.addVertex(Vec3(2, 0, 0));
    m.addEdge(a, d);
    m.addEdge(a, b);
    uint seed = m.edgeIndex(a, b);

    // Arm directly — mirrors `onCtrlLmbDown`'s post-classification state —
    // rather than driving the full down-handler (which needs a live
    // screen-space `findRingSeedEdge` pick); this test targets the
    // RELEASE-side min-drag gate specifically.
    t.slideSeed_   = cast(int)seed;
    t.slideArmed_  = true;
    t.slideStartX_ = 50;
    t.slideStartY_ = 50;
    t.slideEndA_   = cast(int)a;
    t.slideEndB_   = cast(int)b;
    t.slideNbrA_   = cast(int)d;
    t.slideNbrB_   = -1;
    t.slideAnchor_ = Vec3(1, 0, 0);
    // A deliberately NON-zero pending scalar: the gate must reject on pixel
    // travel alone, without relying on the scalar happening to be ~0.
    t.slideDeltaK_ = 0.5f;

    auto before = MeshSnapshot.capture(m);
    SDL_MouseButtonEvent e;
    e.button = SDL_BUTTON_LEFT;
    e.x = 51;
    e.y = 50;   // 1px away — well inside kMinDragPx
    VectorStack vts;
    bool consumed = t.slideUp(e, vts);
    auto after = MeshSnapshot.capture(m);

    assert(consumed, "a click-without-drag release must still consume the event");
    assert(!t.slideArmed_, "release must disarm Slide regardless of the min-drag gate");
    assert(after.vertices == before.vertices, "click-without-drag must not move any vertex");
    assert(!history.canUndo(), "click-without-drag must record NO undo entry");
}

// ---------------------------------------------------------------------------
// Slide law — REFERENCE PARITY CONFORMANCE (the primary gate for this
// gesture's parameterisation: `dominantAxisDelta` + `slideEndpointPos` +
// `continuationNeighbor`, driven through the REAL `commitSlide` path).
//
// 20 independently-captured gestures over 3 meshes, each giving the mesh, the
// grabbed edge, the reference's own world-space move delta for the committed
// evaluation, and the exact post-gesture vertex positions. Feeding the
// RECORDED delta in — rather than a pixel drag — is deliberate and is what
// makes this a real gate: it tests axis extraction, rail resolution and rail
// ORIENTATION independently of our gain, which is a documented divergence
// (see `slideDeltaFromDrag`). A wrong sign, a wrong rail, or a surviving
// `[0,1]` clamp all fail here; only the magnitude curve is out of scope.
//
// Tolerance 1e-7, the fixture's own. A correct port lands at 3.3e-08, which
// is the float STORAGE granularity of the captured targets — i.e. the floor,
// not a slack budget. Anything materially above it means the law drifted.
//
// SPLIT BY DETERMINACY. 16 of the 20 cases grab an edge whose endpoints each
// have exactly ONE continuation edge; those are asserted against
// `expected_vertices`, and their resolved rails are additionally cross-checked
// against the captured ones (32/32 endpoints). The other 4 have TWO
// continuation candidates per endpoint, where the reference's selection is
// sign-dependent and undetermined (`continuationNeighbor`'s doc comment), so
// this tool holds those endpoints FIXED by design. For those the test asserts
// exactly that — no movement, no undo entry — instead of asserting positions
// we deliberately do not reproduce. That is the shipped contract under test,
// not a weakened assertion; asserting `expected_vertices` there would require
// guessing the selection rule.
//
// On the rail ORIENTATION, which is the subtle half of this law: the source
// contract phrases it as the continuation edge's direction "as traversed in
// its polygon's winding". Measured over these 32 determinate endpoints that
// reproduces only 16 — a polygon walk departs from one end of the grabbed
// edge and ARRIVES at the other, so the raw traversal points inward at one of
// them. `unit(neighbor - endpoint)`, i.e. the same edge taken oriented AWAY
// from the grabbed edge, is 32/32. Half these cases invert under the other
// reading, which is why the assertions below are on positions.
// ---------------------------------------------------------------------------
unittest {
    import std.format : format;
    import view       : View;
    import editmode   : EditMode;

    static immutable double[3][8] run11BoundaryVerts = [
        [0.49750889051610303, -0.41370677261163746, -0.03908497105394376],
        [0.36219140916061615, -0.35986172605662464, 0.1441044938142526],
        [-0.15470460441553574, 0.27729932133893814, -0.4249950066121535],
        [-0.019387123060048833, 0.22345427478392532, -0.6081844714803498],
        [-0.011595571798637481, -0.045949952078994126, 0.16439239563592428],
        [-0.13274307498054808, 0.10338466840434088, 0.031009700223485356],
        [-0.36729337599672546, 0.19671608243302977, 0.3485381059950258],
        [-0.24614587281481487, 0.04738146194969475, 0.4819208014074648],
    ];
    static immutable uint[][2] run11BoundaryFaces = [
        [3u, 2u, 1u, 0u],
        [4u, 5u, 6u, 7u],
    ];

    static immutable double[3][6] run13StripVerts = [
        [0.2678946589037937, -0.2549208077455667, 0.0735016433594463],
        [0.09021165423699151, -0.03589669770334199, -0.12212630991213082],
        [-0.08747135042981072, 0.18312741233888274, -0.3177542631837079],
        [0.08747135042981116, -0.18312741233888297, 0.31775426318370814],
        [-0.09021165423699107, 0.035896697703341765, 0.12212630991213104],
        [-0.26789465890379327, 0.25492080774556647, -0.07350164335944608],
    ];
    static immutable uint[][2] run13StripFaces = [
        [0u, 1u, 4u, 3u],
        [1u, 2u, 5u, 4u],
    ];

    static immutable double[3][6] run14BentVerts = [
        [0.2678946589037937, -0.2549208077455667, 0.0735016433594463],
        [0.09021165423699151, -0.03589669770334199, -0.12212630991213082],
        [0.09171882133094071, 0.04508019534620554, -0.3640606251148423],
        [0.08747135042981116, -0.18312741233888297, 0.31775426318370814],
        [-0.09021165423699107, 0.035896697703341765, 0.12212630991213104],
        [-0.2048835161282584, 0.2224315836214501, -0.13699603164314578],
    ];
    static immutable uint[][2] run14BentFaces = [
        [0u, 1u, 4u, 3u],
        [1u, 2u, 5u, 4u],
    ];

    static immutable double[3][8] exp00 = [
        [0.6394095420837402, -0.5886231660842896, 0.1171468198299408],
        [0.5040920376777649, -0.5347781181335449, 0.3003362715244293],
        [-0.15470460057258606, 0.27729931473731995, -0.4249950051307678],
        [-0.019387122243642807, 0.2234542816877365, -0.6081844568252563],
        [-0.011595571413636208, -0.04594995081424713, 0.1643923968076706],
        [-0.13274307548999786, 0.10338466614484787, 0.031009700149297714],
        [-0.3672933876514435, 0.1967160850763321, 0.3485381007194519],
        [-0.24614587426185608, 0.047381460666656494, 0.4819208085536957],
    ];
    static immutable double[3][8] exp01 = [
        [0.3714374601840973, -0.25830259919166565, -0.177888885140419],
        [0.23611997067928314, -0.20445753633975983, 0.005300584714859724],
        [-0.15470460057258606, 0.27729931473731995, -0.4249950051307678],
        [-0.019387122243642807, 0.2234542816877365, -0.6081844568252563],
        [-0.011595571413636208, -0.04594995081424713, 0.1643923968076706],
        [-0.13274307548999786, 0.10338466614484787, 0.031009700149297714],
        [-0.3672933876514435, 0.1967160850763321, 0.3485381007194519],
        [-0.24614587426185608, 0.047381460666656494, 0.4819208085536957],
    ];
    static immutable double[3][8] exp02 = [
        [0.6394095420837402, -0.5886231660842896, 0.1171468198299408],
        [0.5040920376777649, -0.5347781181335449, 0.3003362715244293],
        [-0.15470460057258606, 0.27729931473731995, -0.4249950051307678],
        [-0.019387122243642807, 0.2234542816877365, -0.6081844568252563],
        [-0.011595571413636208, -0.04594995081424713, 0.1643923968076706],
        [-0.13274307548999786, 0.10338466614484787, 0.031009700149297714],
        [-0.3672933876514435, 0.1967160850763321, 0.3485381007194519],
        [-0.24614587426185608, 0.047381460666656494, 0.4819208085536957],
    ];
    static immutable double[3][8] exp03 = [
        [0.5381929874420166, -0.4638567268848419, 0.0057079605758190155],
        [0.40287548303604126, -0.4100116789340973, 0.18889743089675903],
        [-0.15470460057258606, 0.27729931473731995, -0.4249950051307678],
        [-0.019387122243642807, 0.2234542816877365, -0.6081844568252563],
        [-0.011595571413636208, -0.04594995081424713, 0.1643923968076706],
        [-0.13274307548999786, 0.10338466614484787, 0.031009700149297714],
        [-0.3672933876514435, 0.1967160850763321, 0.3485381007194519],
        [-0.24614587426185608, 0.047381460666656494, 0.4819208085536957],
    ];
    static immutable double[3][8] exp04 = [
        [0.5864051580429077, -0.5232864022254944, 0.05878932401537895],
        [0.45108771324157715, -0.46944132447242737, 0.24197879433631897],
        [-0.15470460057258606, 0.27729931473731995, -0.4249950051307678],
        [-0.019387122243642807, 0.2234542816877365, -0.6081844568252563],
        [-0.011595571413636208, -0.04594995081424713, 0.1643923968076706],
        [-0.13274307548999786, 0.10338466614484787, 0.031009700149297714],
        [-0.3672933876514435, 0.1967160850763321, 0.3485381007194519],
        [-0.24614587426185608, 0.047381460666656494, 0.4819208085536957],
    ];
    static immutable double[3][8] exp05 = [
        [0.7193203568458557, -0.6871265769004822, 0.20512813329696655],
        [0.5840028524398804, -0.6332815289497375, 0.38831761479377747],
        [-0.15470460057258606, 0.27729931473731995, -0.4249950051307678],
        [-0.019387122243642807, 0.2234542816877365, -0.6081844568252563],
        [-0.011595571413636208, -0.04594995081424713, 0.1643923968076706],
        [-0.13274307548999786, 0.10338466614484787, 0.031009700149297714],
        [-0.3672933876514435, 0.1967160850763321, 0.3485381007194519],
        [-0.24614587426185608, 0.047381460666656494, 0.4819208085536957],
    ];
    static immutable double[3][8] exp06 = [
        [0.6394095420837402, -0.5886231660842896, 0.1171468198299408],
        [0.5040920376777649, -0.5347781181335449, 0.3003362715244293],
        [-0.15470460057258606, 0.27729931473731995, -0.4249950051307678],
        [-0.019387122243642807, 0.2234542816877365, -0.6081844568252563],
        [-0.011595571413636208, -0.04594995081424713, 0.1643923968076706],
        [-0.13274307548999786, 0.10338466614484787, 0.031009700149297714],
        [-0.3672933876514435, 0.1967160850763321, 0.3485381007194519],
        [-0.24614587426185608, 0.047381460666656494, 0.4819208085536957],
    ];
    static immutable double[3][8] exp07 = [
        [0.4104355275630951, -0.3063742518424988, -0.13495221734046936],
        [0.27511805295944214, -0.25252923369407654, 0.04823724552989006],
        [-0.15470460057258606, 0.27729931473731995, -0.4249950051307678],
        [-0.019387122243642807, 0.2234542816877365, -0.6081844568252563],
        [-0.011595571413636208, -0.04594995081424713, 0.1643923968076706],
        [-0.13274307548999786, 0.10338466614484787, 0.031009700149297714],
        [-0.3672933876514435, 0.1967160850763321, 0.3485381007194519],
        [-0.24614587426185608, 0.047381460666656494, 0.4819208085536957],
    ];
    static immutable double[3][8] exp08 = [
        [0.4975088834762573, -0.41370677947998047, -0.03908497095108032],
        [0.36219140887260437, -0.35986173152923584, 0.1441044956445694],
        [0.09341167658567429, -0.028545614331960678, -0.15182043612003326],
        [0.22872914373874664, -0.08239065110683441, -0.335009902715683],
        [-0.011595571413636208, -0.04594995081424713, 0.1643923968076706],
        [-0.13274307548999786, 0.10338466614484787, 0.031009700149297714],
        [-0.3672933876514435, 0.1967160850763321, 0.3485381007194519],
        [-0.24614587426185608, 0.047381460666656494, 0.4819208085536957],
    ];
    static immutable double[3][8] exp09 = [
        [0.4975088834762573, -0.41370677947998047, -0.03908497095108032],
        [0.36219140887260437, -0.35986173152923584, 0.1441044956445694],
        [-0.3369227945804596, 0.5019137859344482, -0.625616192817688],
        [-0.20160531997680664, 0.4480687975883484, -0.8088056445121765],
        [-0.011595571413636208, -0.04594995081424713, 0.1643923968076706],
        [-0.13274307548999786, 0.10338466614484787, 0.031009700149297714],
        [-0.3672933876514435, 0.1967160850763321, 0.3485381007194519],
        [-0.24614587426185608, 0.047381460666656494, 0.4819208085536957],
    ];
    static immutable double[3][8] exp10 = [
        [0.4975088834762573, -0.41370677947998047, -0.03908497095108032],
        [0.36219140887260437, -0.35986173152923584, 0.1441044956445694],
        [-0.15470460057258606, 0.27729931473731995, -0.4249950051307678],
        [-0.019387122243642807, 0.2234542816877365, -0.6081844568252563],
        [-0.1161508783698082, -0.004345679190009832, 0.3059367835521698],
        [-0.237298384308815, 0.14498893916606903, 0.17255409061908722],
        [-0.3672933876514435, 0.1967160850763321, 0.3485381007194519],
        [-0.24614587426185608, 0.047381460666656494, 0.4819208085536957],
    ];
    static immutable double[3][8] exp11 = [
        [0.4975088834762573, -0.41370677947998047, -0.03908497095108032],
        [0.36219140887260437, -0.35986173152923584, 0.1441044956445694],
        [-0.15470460057258606, 0.27729931473731995, -0.4249950051307678],
        [-0.019387122243642807, 0.2234542816877365, -0.6081844568252563],
        [-0.11959760636091232, -0.002974170260131359, 0.3106028735637665],
        [-0.24074511229991913, 0.14636044204235077, 0.1772201806306839],
        [-0.3672933876514435, 0.1967160850763321, 0.3485381007194519],
        [-0.24614587426185608, 0.047381460666656494, 0.4819208085536957],
    ];
    static immutable double[3][6] exp12 = [
        [0.2678946554660797, -0.2549208104610443, 0.07350164651870728],
        [-0.2885283827781677, 0.430963933467865, -0.5391168594360352],
        [-0.08747135102748871, 0.18312741816043854, -0.31775426864624023],
        [0.08747135102748871, -0.18312741816043854, 0.31775426864624023],
        [-0.46895167231559753, 0.5027573108673096, -0.2948642671108246],
        [-0.2678946554660797, 0.2549208104610443, -0.07350164651870728],
    ];
    static immutable double[3][6] exp13 = [
        [0.2678946554660797, -0.2549208104610443, 0.07350164651870728],
        [0.26759618520736694, -0.2545529007911682, 0.07317303866147995],
        [-0.08747135102748871, 0.18312741816043854, -0.31775426864624023],
        [0.08747135102748871, -0.18312741816043854, 0.31775426864624023],
        [0.08717288821935654, -0.18275950849056244, 0.3174256682395935],
        [-0.2678946554660797, 0.2549208104610443, -0.07350164651870728],
    ];
    static immutable double[3][6] exp14 = [
        [0.48049625754356384, -0.5169879794120789, 0.3075747787952423],
        [0.0902116522192955, -0.03589669615030289, -0.12212631106376648],
        [-0.08747135102748871, 0.18312741816043854, -0.31775426864624023],
        [0.30007296800613403, -0.4451945722103119, 0.5518273711204529],
        [-0.0902116522192955, 0.03589669615030289, 0.12212631106376648],
        [-0.2678946554660797, 0.2549208104610443, -0.07350164651870728],
    ];
    static immutable double[3][6] exp15 = [
        [0.14727678894996643, -0.10623905807733536, -0.05929791182279587],
        [0.0902116522192955, -0.03589669615030289, -0.12212631106376648],
        [-0.08747135102748871, 0.18312741816043854, -0.31775426864624023],
        [-0.033146511763334274, -0.03444566950201988, 0.1849547028541565],
        [-0.0902116522192955, 0.03589669615030289, 0.12212631106376648],
        [-0.2678946554660797, 0.2549208104610443, -0.07350164651870728],
    ];
    static immutable double[3][6] exp16 = [
        [0.2678946554660797, -0.2549208104610443, 0.07350164651870728],
        [0.09385570138692856, 0.1598898470401764, -0.707076907157898],
        [0.09171882271766663, 0.04508019611239433, -0.3640606105327606],
        [0.08747135102748871, -0.18312741816043854, 0.31775426864624023],
        [-0.2987203001976013, 0.3750743865966797, -0.34903764724731445],
        [-0.20488351583480835, 0.22243158519268036, -0.13699603080749512],
    ];
    static immutable double[3][6] exp17 = [
        [0.2678946554660797, -0.2549208104610443, 0.07350164651870728],
        [0.28252652287483215, -0.2729570269584656, 0.0896112322807312],
        [0.09171882271766663, 0.04508019611239433, -0.3640606105327606],
        [0.08747135102748871, -0.18312741816043854, 0.31775426864624023],
        [0.10210320353507996, -0.2011636346578598, 0.33386385440826416],
        [-0.20488351583480835, 0.22243158519268036, -0.13699603080749512],
    ];
    static immutable double[3][6] exp18 = [
        [0.07406548410654068, -0.015993835404515266, -0.13990314304828644],
        [0.0902116522192955, -0.03589669615030289, -0.12212631106376648],
        [0.09171882271766663, 0.04508019611239433, -0.3640606105327606],
        [-0.10635782033205032, 0.05579955875873566, 0.10434948652982712],
        [-0.0902116522192955, 0.03589669615030289, 0.12212631106376648],
        [-0.20488351583480835, 0.22243158519268036, -0.13699603080749512],
    ];
    static immutable double[3][6] exp19 = [
        [0.40300917625427246, -0.42147210240364075, 0.2222619205713272],
        [0.0902116522192955, -0.03589669615030289, -0.12212631106376648],
        [0.09171882271766663, 0.04508019611239433, -0.3640606105327606],
        [0.22258585691452026, -0.34967872500419617, 0.46651455760002136],
        [-0.0902116522192955, 0.03589669615030289, 0.12212631106376648],
        [-0.20488351583480835, 0.22243158519268036, -0.13699603080749512],
    ];

    struct Case {
        string id; int mesh; uint ga, gb; double[3] delta; int domAxis;
        int railA, railB;            // -1 = fixture reports no rail for that endpoint
        bool determinate;            // false = MULTI-candidate endpoint, held fixed here
        const(double[3])[] expect;
    }
    static immutable Case[20] cases = [
        Case("run11_boundary/A_step02", 0, 0u, 1u, [0.0, 0.2741165855213294, 0.0], 1, 3, 2, true, exp00[]),
        Case("run11_boundary/A_step03", 0, 0u, 1u, [0.0, 0.0, -0.24353848868170486], 2, 3, 2, true, exp01[]),
        Case("run11_boundary/A_step06", 0, 0u, 1u, [0.0, 0.2741165855213294, 0.0], 1, 3, 2, true, exp02[]),
        Case("run11_boundary/B_px060", 0, 0u, 1u, [0.0, 0.0785914666275071, 0.0], 1, 3, 2, true, exp03[]),
        Case("run11_boundary/B_px120", 0, 0u, 1u, [0.0, 0.17172540888373483, 0.0], 1, 3, 2, true, exp04[]),
        Case("run11_boundary/B_px240", 0, 0u, 1u, [0.0, 0.4284842559971134, 0.0], 1, 3, 2, true, exp05[]),
        Case("run11_boundary/C_S_p", 0, 0u, 1u, [0.0, 0.2741165855213294, 0.0], 1, 3, 2, true, exp06[]),
        Case("run11_boundary/C_S_m", 0, 0u, 1u, [0.0, -0.16820394089168939, 0.0], 1, 3, 2, true, exp07[]),
        Case("run11_boundary/C_F_p", 0, 2u, 3u, [0.0, -0.47929860233631355, 0.0], 1, 1, 0, true, exp08[]),
        Case("run11_boundary/C_F_m", 0, 2u, 3u, [0.0, 0.352, 0.0], 1, 1, 0, true, exp09[]),
        Case("run11_boundary/C_C_p", 0, 4u, 5u, [-0.18082462078503622, 0.0, 0.0], 0, 7, 6, true, exp10[]),
        Case("run11_boundary/C_C_m", 0, 4u, 5u, [0.0, 0.0, -0.1867856083621176], 2, 7, 6, true, exp11[]),
        Case("run13_strip/I_shared_p", 1, 1u, 4u, [0.0, 0.7316310550781467, 0.0], 1, 2, 5, false, exp12[]),
        Case("run13_strip/I_shared_m", 1, 1u, 4u, [0.0, -0.3426625872266482, 0.0], 1, 2, 5, false, exp13[]),
        Case("run13_strip/I_outer_p", 1, 0u, 3u, [0.0, 0.41069314088024644, 0.0], 1, 1, 4, true, exp14[]),
        Case("run13_strip/I_outer_m", 1, 0u, 3u, [0.0, -0.23300354934593515, 0.0], 1, 1, 4, true, exp15[]),
        Case("run14_bent/I_shared_p", 2, 1u, 4u, [0.0, 0.0, -0.6168572132788047], 2, 2, 5, false, exp16[]),
        Case("run14_bent/I_shared_m", 2, 1u, 4u, [0.0, 0.0, 0.37150423149664574], 2, 0, 3, false, exp17[]),
        Case("run14_bent/I_outer_p", 2, 0u, 3u, [0.0, 0.0, -0.3744295004047694], 2, 1, 4, true, exp18[]),
        Case("run14_bent/I_outer_m", 2, 0u, 3u, [0.0, 0.0, 0.26100744462938286], 2, 1, 4, true, exp19[]),
    ];

    string report;
    double overallWorst = 0;
    int gated = 0, heldFixed = 0;

    foreach (ref c; cases) {
        auto verts = c.mesh == 0 ? run11BoundaryVerts[]
                   : c.mesh == 1 ? run13StripVerts[]
                                 : run14BentVerts[];
        auto faces = c.mesh == 0 ? run11BoundaryFaces[]
                   : c.mesh == 1 ? run13StripFaces[]
                                 : run14BentFaces[];
        // Two disjoint quads vs a 2-quad strip sharing one edge. Asserted so a
        // face-list transcription error cannot quietly change the topology
        // under test — the rail resolution reads faces, not just positions.
        immutable size_t expectEdges = (c.mesh == 0) ? 8 : 7;

        auto t       = new TopologyPenTool();
        auto view    = new View(0, 0, 100, 100);
        auto history = new CommandHistory();
        t.history_          = history;
        t.slideEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                        "mesh.topoPen_slide", "Topology Slide",
                                                        MeshEditScope.Position);
        Mesh m;
        t.meshSrc_ = () => &m;
        foreach (v; verts)
            m.addVertex(Vec3(cast(float) v[0], cast(float) v[1], cast(float) v[2]));
        foreach (fc; faces) m.addFace(fc.dup);
        m.buildLoops();

        assert(m.vertices.length == verts.length && m.faces.length == faces.length
            && m.edges.length == expectEdges,
            format("case %s: rebuilt rig must match the captured one "
                 ~ "(%d verts / %d edges / %d faces); got %d/%d/%d",
                   c.id, verts.length, expectEdges, faces.length,
                   m.vertices.length, m.edges.length, m.faces.length));

        uint seed = m.edgeIndex(c.ga, c.gb);
        assert(seed != uint.max,
            format("case %s: the grabbed edge %d-%d must exist", c.id, c.ga, c.gb));

        // --- Axis extraction, checked against the reference's OWN recorded
        // dominant axis rather than against our own re-derivation of it. ---
        Vec3 dv = Vec3(cast(float) c.delta[0], cast(float) c.delta[1], cast(float) c.delta[2]);
        float gotAxisVal = TopologyPenTool.dominantAxisDelta(dv);
        immutable float wantAxisVal = c.domAxis == 0 ? dv.x : c.domAxis == 1 ? dv.y : dv.z;
        assert(gotAxisVal == wantAxisVal,
            format("case %s: argmax|delta| must select world axis %d", c.id, c.domAxis));
        // Consume the FULL-precision component, not the float round-trip —
        // see `slideEndpointPos` on why the API is double.
        immutable double deltaK = c.delta[c.domAxis];

        int nA = TopologyPenTool.continuationNeighbor(&m, c.ga, c.gb);
        int nB = TopologyPenTool.continuationNeighbor(&m, c.gb, c.ga);

        auto before = MeshSnapshot.capture(m);
        t.commitSlide(seed, cast(int) c.ga, cast(int) c.gb, nA, nB, deltaK);

        assert(m.vertices.length == verts.length && m.edges.length == expectEdges
            && m.faces.length == faces.length,
            format("case %s: slide is position-only — topology must be untouched", c.id));

        if (!c.determinate) {
            // MULTI-candidate endpoints: selection is undetermined, so both
            // ends are held fixed and the whole gesture is a clean no-op.
            ++heldFixed;
            assert(nA == -1 && nB == -1,
                format("case %s: a multi-continuation endpoint must resolve to NO rail "
                     ~ "(-1); got %d/%d — a tie-break has slipped in", c.id, nA, nB));
            assert(m.vertices == before.vertices,
                format("case %s: with neither endpoint slidable the commit must not "
                     ~ "move any vertex", c.id));
            assert(!history.canUndo(),
                format("case %s: a both-fixed slide must record NO undo entry", c.id));
            continue;
        }

        ++gated;
        assert(nA == c.railA && nB == c.railB,
            format("case %s: resolved rails must match the captured ones "
                 ~ "(%d/%d); got %d/%d", c.id, c.railA, c.railB, nA, nB));

        double worst = 0;
        size_t worstAt = 0;
        foreach (i; 0 .. verts.length) {
            auto e = c.expect[i];
            const double dx = cast(double) m.vertices[i].x - e[0];
            const double dy = cast(double) m.vertices[i].y - e[1];
            const double dz = cast(double) m.vertices[i].z - e[2];
            import std.math : sqrt;
            const double dist = sqrt(dx * dx + dy * dy + dz * dz);
            if (dist > worst) { worst = dist; worstAt = i; }
        }
        report ~= format("\n    %-26s axis=%d delta=%+.6f worst=%.4e at v%d",
                         c.id, c.domAxis, deltaK, worst, worstAt);
        if (worst > overallWorst) overallWorst = worst;

        // Guard against a vacuous pass: the grabbed endpoints must genuinely
        // move, or "reproduces the target" would be satisfied by doing nothing.
        assert((m.vertices[c.ga] - before.vertices[c.ga]).length > 1e-4f
            && (m.vertices[c.gb] - before.vertices[c.gb]).length > 1e-4f,
            format("case %s: both grabbed endpoints must actually slide", c.id));

        // The captured invariant that both endpoints share ONE scalar: equal
        // travel distance, independent of the two rails' directions/lengths.
        immutable double travA = (m.vertices[c.ga] - before.vertices[c.ga]).length;
        immutable double travB = (m.vertices[c.gb] - before.vertices[c.gb]).length;
        import std.math : abs;
        assert(abs(travA - travB) < 1e-6,
            format("case %s: both endpoints must travel the same distance "
                 ~ "(%.9f vs %.9f)", c.id, travA, travB));
        // ...and that distance is |delta[k]| EXACTLY — no clamp anywhere.
        assert(abs(travA - abs(deltaK)) < 1e-6,
            format("case %s: travel must equal |delta[k]| = %.9f exactly (got %.9f) "
                 ~ "— a surviving [0,1] clamp would shorten it", c.id, abs(deltaK), travA));

        assert(history.canUndo(), format("case %s: a real slide must be undoable", c.id));
        history.undo();
        foreach (i; 0 .. verts.length)
            assert((m.vertices[i] - before.vertices[i]).length < 1e-6f,
                format("case %s: one undo must fully revert the gesture", c.id));
    }

    assert(gated == 16 && heldFixed == 4,
        format("the split by determinacy must stay 16 gated / 4 held-fixed; got %d/%d",
               gated, heldFixed));
    assert(overallWorst < 1e-7,
        format("the Slide law must reproduce every determinate captured gesture to the "
             ~ "fixture's 1e-7 (a correct port lands at 3.3e-08); worst over %d cases "
             ~ "= %.4e%s", gated, overallWorst, report));
}

// ---------------------------------------------------------------------------
// Smooth relaxation kernel — REFERENCE PARITY CONFORMANCE (the primary gate
// for `tools/edit/smooth_relax.d`; that module's header states the law and
// the ablation evidence).
//
// Six independently-captured cases over two rigs, replayed through the REAL
// path this tool uses: a `Mesh` built from the rig, `buildRelaxTopology`'s
// own CSR + open-edge extraction, then `relaxPasses`. The expected values
// are the exact positions the reference kernel produces BEFORE its per-vertex
// background re-snap — i.e. precisely the output this kernel must reproduce
// — read at full double precision and stable across independent capture
// sessions. Coverage: both rig orientations, strength 1.0 and 0.5, a single
// iteration and a 57-iteration run, and the two lock flags.
//
// Tolerance: 1e-9. A correct port lands near 1e-16 (the fixture's own
// clean-room verifier reaches 2.3e-16); the four orders of margin absorb
// only the neighbour-summation ORDER difference between that verifier's
// sorted 1-ring and this mesh's CSR order. Anything approaching 1e-9 means
// the law itself has drifted, not that the arithmetic reassociated.
//
// The two lock cases are the load-bearing evidence for NOT implementing
// `lockBound`/`lockCorner` on this path: their expected positions are
// IDENTICAL to the unlocked case's, boundary and corner vertices included.
// See `applySmoothPasses`'s doc comment.
// ---------------------------------------------------------------------------
unittest {
    import std.format : format;
    import std.math   : abs;

    string report;          // every case's worst error, so ONE failure shows the whole picture
    double overallWorst = 0;

    // Shared topology (the two rigs are the same builder output, differing
    // only in orientation, so edges/faces are identical).
    static immutable uint[][9] rigFaces = [
        [0u,2u,3u,1u],
        [2u,4u,5u,3u],
        [4u,6u,7u,5u],
        [6u,8u,9u,7u],
        [10u,11u,12u],
        [10u,12u,13u],
        [10u,13u,14u],
        [10u,14u,15u],
        [10u,15u,11u],
    ];
    enum size_t kRigEdgeCount = 23;
    static immutable double[3][16] rigAVerts = [
        [-0.3499999940395355, -0.05000000074505806, 0.55859375],
        [-0.3499999940395355, 0.05000000074505806, 0.55859375],
        [-0.2800000011920929, -0.05000000074505806, 0.6274999976158142],
        [-0.2800000011920929, 0.05000000074505806, 0.6274999976158142],
        [0.0, -0.05000000074505806, 0.75],
        [0.0, 0.05000000074505806, 0.75],
        [0.10000000149011612, -0.05000000074505806, 0.734375],
        [0.10000000149011612, 0.05000000074505806, 0.734375],
        [0.3499999940395355, -0.05000000074505806, 0.55859375],
        [0.3499999940395355, 0.05000000074505806, 0.55859375],
        [0.75, 0.0, 0.5],
        [1.0499999523162842, 0.05000000074505806, 0.5],
        [0.8999999761581421, 0.2800000011920929, 0.5],
        [0.6499999761581421, 0.20000000298023224, 0.5],
        [0.4699999988079071, -0.05000000074505806, 0.5],
        [0.8299999833106995, -0.25, 0.5],
    ];
    static immutable double[3][16] rigBVerts = [
        [0.55859375, -0.3499999940395355, -0.05000000074505806],
        [0.55859375, -0.3499999940395355, 0.05000000074505806],
        [0.6274999976158142, -0.2800000011920929, -0.05000000074505806],
        [0.6274999976158142, -0.2800000011920929, 0.05000000074505806],
        [0.75, 0.0, -0.05000000074505806],
        [0.75, 0.0, 0.05000000074505806],
        [0.734375, 0.10000000149011612, -0.05000000074505806],
        [0.734375, 0.10000000149011612, 0.05000000074505806],
        [0.55859375, 0.3499999940395355, -0.05000000074505806],
        [0.55859375, 0.3499999940395355, 0.05000000074505806],
        [0.5, 0.75, 0.0],
        [0.5, 1.0499999523162842, 0.05000000074505806],
        [0.5, 0.8999999761581421, 0.2800000011920929],
        [0.5, 0.6499999761581421, 0.20000000298023224],
        [0.5, 0.4699999988079071, -0.05000000074505806],
        [0.5, 0.8299999833106995, -0.25],
    ];

    // The six captured cases: rig, strength, iteration count, and the exact
    // pre-re-snap position the reference kernel produces for every vertex.
    struct Case { string id; bool rigB; double strength; int iters; const(double[3])[] expect; }
    static immutable double[3][16] expect0 = [
        [-0.3509309595007398, -0.047522392129164905, 0.5595394926268349],
        [-0.3509309595007398, 0.047522392129164905, 0.5595394926268349],
        [-0.2793560716931852, -0.052477609360951215, 0.6272103371785385],
        [-0.2793560716931852, 0.052477609360951215, 0.6272103371785385],
        [0.0002310144766059759, -0.05000000074505806, 0.7489853802966783],
        [0.0002310144766059759, 0.05000000074505806, 0.7489853802966783],
        [0.09908954754612097, -0.05376729737875115, 0.7333589947213962],
        [0.09908954754612097, 0.05376729737875115, 0.7333589947213962],
        [0.3509664694692213, -0.04623270411136497, 0.5599682927923663],
        [0.3509664694692213, 0.04623270411136497, 0.5599682927923663],
        [0.7531294454837306, 0.005525881341248126, 0.5],
        [1.0514480743992267, 0.04595558369844894, 0.5],
        [0.9012222446670399, 0.278483298147573, 0.5],
        [0.6439291070734187, 0.20394696446603477, 0.5],
        [0.47358182993924025, -0.05548756388530698, 0.5],
        [0.8266891851885189, -0.24842415959567274, 0.5],
    ];
    static immutable double[3][16] expect1 = [
        [0.5595394926268349, -0.3509309595007398, -0.047522392129164905],
        [0.5595394926268349, -0.3509309595007398, 0.047522392129164905],
        [0.6272103371785385, -0.2793560716931852, -0.052477609360951215],
        [0.6272103371785385, -0.2793560716931852, 0.052477609360951215],
        [0.7489853802966783, 0.0002310144766059759, -0.05000000074505806],
        [0.7489853802966783, 0.0002310144766059759, 0.05000000074505806],
        [0.7333589947213962, 0.09908954754612097, -0.05376729737875115],
        [0.7333589947213962, 0.09908954754612097, 0.05376729737875115],
        [0.5599682927923663, 0.3509664694692213, -0.04623270411136497],
        [0.5599682927923663, 0.3509664694692213, 0.04623270411136497],
        [0.5, 0.7531294454837306, 0.005525881341248126],
        [0.5, 1.0514480743992267, 0.04595558369844894],
        [0.5, 0.9012222446670399, 0.278483298147573],
        [0.5, 0.6439291070734187, 0.20394696446603477],
        [0.5, 0.47358182993924025, -0.05548756388530698],
        [0.5, 0.8266891851885189, -0.24842415959567274],
    ];
    static immutable double[3][16] expect2 = [
        [0.5590666213134174, -0.3504654767701377, -0.04876119643711148],
        [0.5590666213134174, -0.3504654767701377, 0.04876119643711148],
        [0.6273551673971763, -0.27967803644263906, -0.05123880505300464],
        [0.6273551673971763, -0.27967803644263906, 0.05123880505300464],
        [0.7494926901483392, 0.00011550723830298796, -0.05000000074505806],
        [0.7494926901483392, 0.00011550723830298796, 0.05000000074505806],
        [0.7338669973606982, 0.09954477451811855, -0.0518836490619046],
        [0.7338669973606982, 0.09954477451811855, 0.0518836490619046],
        [0.5592810213961832, 0.3504832317543784, -0.048116352428211516],
        [0.5592810213961832, 0.3504832317543784, 0.048116352428211516],
        [0.5, 0.7515647227418654, 0.002762940670624063],
        [0.5, 1.0507240133577553, 0.047977792221753496],
        [0.5, 0.900611110412591, 0.27924164966983295],
        [0.5, 0.6469645416157803, 0.2019734837231335],
        [0.5, 0.4717909143735737, -0.05274378231518252],
        [0.5, 0.8283445842496092, -0.24921207979783636],
    ];
    static immutable double[3][16] expect3 = [
        [0.5595394926268349, -0.3509309595007398, -0.047522392129164905],
        [0.5595394926268349, -0.3509309595007398, 0.047522392129164905],
        [0.6272103371785385, -0.2793560716931852, -0.052477609360951215],
        [0.6272103371785385, -0.2793560716931852, 0.052477609360951215],
        [0.7489853802966783, 0.0002310144766059759, -0.05000000074505806],
        [0.7489853802966783, 0.0002310144766059759, 0.05000000074505806],
        [0.7333589947213962, 0.09908954754612097, -0.05376729737875115],
        [0.7333589947213962, 0.09908954754612097, 0.05376729737875115],
        [0.5599682927923663, 0.3509664694692213, -0.04623270411136497],
        [0.5599682927923663, 0.3509664694692213, 0.04623270411136497],
        [0.5, 0.7531294454837306, 0.005525881341248126],
        [0.5, 1.0514480743992267, 0.04595558369844894],
        [0.5, 0.9012222446670399, 0.278483298147573],
        [0.5, 0.6439291070734187, 0.20394696446603477],
        [0.5, 0.47358182993924025, -0.05548756388530698],
        [0.5, 0.8266891851885189, -0.24842415959567274],
    ];
    static immutable double[3][16] expect4 = [
        [0.5595394926268349, -0.3509309595007398, -0.047522392129164905],
        [0.5595394926268349, -0.3509309595007398, 0.047522392129164905],
        [0.6272103371785385, -0.2793560716931852, -0.052477609360951215],
        [0.6272103371785385, -0.2793560716931852, 0.052477609360951215],
        [0.7489853802966783, 0.0002310144766059759, -0.05000000074505806],
        [0.7489853802966783, 0.0002310144766059759, 0.05000000074505806],
        [0.7333589947213962, 0.09908954754612097, -0.05376729737875115],
        [0.7333589947213962, 0.09908954754612097, 0.05376729737875115],
        [0.5599682927923663, 0.3509664694692213, -0.04623270411136497],
        [0.5599682927923663, 0.3509664694692213, 0.04623270411136497],
        [0.5, 0.7531294454837306, 0.005525881341248126],
        [0.5, 1.0514480743992267, 0.04595558369844894],
        [0.5, 0.9012222446670399, 0.278483298147573],
        [0.5, 0.6439291070734187, 0.20394696446603477],
        [0.5, 0.47358182993924025, -0.05548756388530698],
        [0.5, 0.8266891851885189, -0.24842415959567274],
    ];
    static immutable double[3][16] expect5 = [
        [0.5962737273978181, -0.363094558491022, -0.015080484073826325],
        [0.5962737273978181, -0.363094558491022, 0.015080484073826325],
        [0.626922080802297, -0.27763038288802244, -0.052343801519729456],
        [0.626922080802297, -0.27763038288802244, 0.052343801519729456],
        [0.6965278116823995, 0.00827632716910339, -0.09207342573683973],
        [0.6965278116823995, 0.00827632716910339, 0.09207342573683973],
        [0.6937818213225817, 0.08148025116265885, -0.08522879883085108],
        [0.6937818213225817, 0.08148025116265885, 0.08522879883085108],
        [0.6155570564107176, 0.37096836334530564, -0.005273493564043758],
        [0.6155570564107176, 0.37096836334530564, 0.005273493564043758],
        [0.5, 0.7749926766641773, 0.03832796273685365],
        [0.5, 1.0515001104481065, 0.006508481493563776],
        [0.5, 0.9192413876921455, 0.2789238997470296],
        [0.5, 0.5861224012616796, 0.22484105746251834],
        [0.5, 0.5177956877733761, -0.08903431310515317],
        [0.5, 0.8003476229116904, -0.22956708416248714],
    ];
    static immutable Case[6] cases = [
        Case("click_strength1_iter1", false, 1.0, 1, expect0[]),
        Case("click_strength1_iter1_rigB", true, 1.0, 1, expect1[]),
        Case("click_strength0.5_iter1", true, 0.5, 1, expect2[]),
        Case("click_lockBound_true", true, 1.0, 1, expect3[]),
        Case("click_lockCorner_true", true, 1.0, 1, expect4[]),
        Case("drag_57_iterations", true, 1.0, 57, expect5[]),
    ];

    foreach (ci, ref c; cases) {
        auto verts = c.rigB ? rigBVerts[] : rigAVerts[];

        Mesh m;
        foreach (v; verts) m.addVertex(Vec3(cast(float) v[0], cast(float) v[1], cast(float) v[2]));
        foreach (f; rigFaces) m.addFace(f.dup);
        m.buildLoops();

        // Rig sanity: the faces must derive exactly the captured edge set, or
        // the topology under test is not the topology that was measured.
        assert(m.vertices.length == verts.length && m.edges.length == kRigEdgeCount
            && m.faces.length == rigFaces.length,
            format("case %s: rebuilt rig must match the captured one "
                 ~ "(%d verts / %d edges / %d faces); got %d/%d/%d",
                   c.id, verts.length, kRigEdgeCount, rigFaces.length,
                   m.vertices.length, m.edges.length, m.faces.length));

        auto topo = TopologyPenTool.buildRelaxTopology(&m);
        assert(topo.valid(m.vertices.length), "extracted topology must be self-consistent");

        // Seed from `m.vertices`, NOT from the fixture's own doubles — this
        // is the float→double widening `applySmoothPasses` itself performs,
        // so the gate covers that step instead of bypassing it. Bit-identical
        // either way today (every captured coordinate is float-exact), which
        // is precisely why seeding from the rig would silently leave the
        // conversion untested.
        auto pos = new RelaxVec3[](verts.length);
        foreach (i; 0 .. m.vertices.length)
            pos[i] = RelaxVec3(m.vertices[i].x, m.vertices[i].y, m.vertices[i].z);

        relaxPasses(pos, topo, c.strength / 20.0, c.iters);

        double worst = 0;
        size_t worstAt = 0;
        foreach (i; 0 .. verts.length) {
            auto e = c.expect[i];
            auto d = RelaxVec3(pos[i].x - e[0], pos[i].y - e[1], pos[i].z - e[2]).length();
            if (d > worst) { worst = d; worstAt = i; }
        }
        report ~= format("\n    %-28s strength=%-4g iters=%-3d worst=%.4e at v%d",
                         c.id, c.strength, c.iters, worst, worstAt);
        if (worst > overallWorst) overallWorst = worst;

        // Guard against a vacuous pass: the rig must genuinely move, or the
        // comparison above would be satisfied by doing nothing at all.
        double moved = 0;
        foreach (i; 0 .. verts.length)
            moved += RelaxVec3(pos[i].x - verts[i][0], pos[i].y - verts[i][1],
                               pos[i].z - verts[i][2]).length();
        assert(moved > 1e-6, format("case %s: the rig must actually relax", c.id));
    }

    assert(overallWorst < 1e-9,
        format("the Smooth kernel must reproduce every captured reference relaxation target "
             ~ "to 1e-9 (a correct port lands near 1e-16); worst over all %d cases = %.4e%s",
               cases.length, overallWorst, report));
}

// ---------------------------------------------------------------------------
// smoothPassesForDragDx — the MEASURED pass-count law (task 0490):
//
//     N = max(1, 1 + (xCurrent - xPress) / 5)
//
// x-only, SIGNED, truncating toward zero, floored at 1 and capped at the
// runaway backstop. Pinned as a table so the three separable claims are each
// asserted on their own row: the stride is 5px (not 20), the direction is
// signed (leftward lowers the count to its floor instead of raising it), and
// the cap sits far outside the working range.
// ---------------------------------------------------------------------------
unittest {
    import std.format : format;

    static struct PassCase { int dx; int want; string why; }
    static immutable PassCase[] cases = [
        PassCase(    0,   1, "a press with no horizontal travel is exactly one pass"),
        PassCase(    1,   1, "sub-stride travel cannot add a pass"),
        PassCase(    4,   1, "still inside the first 5px stride"),
        PassCase(    5,   2, "the first full stride adds the second pass"),
        PassCase(    9,   2, "the second stride is not complete yet"),
        PassCase(   10,   3, "one extra pass per 5px, exactly"),
        PassCase(   40,   9, "the stride is 5px, not 20: a 40px drag is 9 passes"),
        PassCase(  100,  21, "and a 100px drag is 21, not 6"),
        PassCase( 1275, 256, "the runaway cap is first reached only at +1275px"),
        PassCase( 5000, 256, "and clamps there, never above"),
        PassCase(   -1,   1, "leftward travel floors at 1 — never 0, never negative"),
        PassCase(   -5,   1, "one stride left of the press column is still one pass"),
        PassCase( -100,   1, "and so is a long leftward drag: distance alone adds nothing"),
    ];

    foreach (c; cases) {
        int got = TopologyPenTool.smoothPassesForDragDx(c.dx);
        assert(got == c.want,
            format("dx=%+d must give %d pass(es) — %s; got %d", c.dx, c.want, c.why, got));
    }
}

// ---------------------------------------------------------------------------
// The Smooth gesture FEEDS that law with the right quantity (task 0490):
// the signed horizontal offset of the live cursor from THIS press pixel —
// so vertical motion contributes nothing at all, the accumulated path is
// never consulted (an out-and-back ends where it started, at one pass), and
// nothing survives into the next press. Driven through the REAL dispatch
// (`onMouseButtonDown`/`onMouseMotion`/`onMouseButtonUp`) and observed
// through the same `/api/tool/state` field a Tier-C test reads.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import mesh : makeGridPlane;
    import toolpipe.packets : SubjectPacket;
    import std.format : format;

    loadSDL();
    SDL_SetModState(cast(SDL_Keymod)(KMOD_SHIFT | KMOD_CTRL));
    scope(exit) SDL_SetModState(cast(SDL_Keymod)0);   // don't leak into later dub-test unittests

    auto t    = new TopologyPenTool();
    auto view = new View(0, 0, 200, 200);
    Mesh m    = makeGridPlane(2);
    t.meshSrc_ = () => &m;

    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = view.viewport();
    VectorStack vts;
    vts.put(&subj);

    // `history_`/`smoothEditFactory_` are deliberately left null: this case is
    // about the COUNT the gesture derives, so the release must not mutate the
    // mesh (`applySmoothPasses` returns immediately without them).
    enum int px = 100, py = 100;

    SDL_MouseButtonEvent eDown;
    eDown.button = SDL_BUTTON_LEFT;
    eDown.x = px; eDown.y = py;
    assert(t.onMouseButtonDown(eDown, vts), "Shift+Ctrl+LMB must be consumed by the real dispatch");
    assert(t.smoothArmed_, "Shift+Ctrl+LMB must arm the whole-mesh Smooth gesture");
    assert(cast(int)t.toolStateJson()["smoothPassCount"].integer == 1,
        "a stationary armed press must report exactly one pass");

    int passesAt(int x, int y) {
        SDL_MouseMotionEvent e;
        e.x = x; e.y = y;
        assert(t.onMouseMotion(e, vts), "motion while Smooth is armed must be consumed");
        return cast(int)t.toolStateJson()["smoothPassCount"].integer;
    }

    // Pure VERTICAL motion: 300px straight down is still the click's one pass.
    assert(passesAt(px, py + 300) == 1,
        format("pure vertical motion must contribute NO passes; got %d", passesAt(px, py + 300)));

    // Horizontal offset is the whole input — and the same offset gives the
    // same count whatever y does.
    assert(passesAt(px + 40, py + 300) == 9, "a +40px horizontal offset is 9 passes");
    assert(passesAt(px + 40, py) == 9, "the count must not depend on y at all");

    // Left of the press column: floored at 1, and the ~400px of path already
    // walked to get here contributes nothing.
    assert(passesAt(px - 40, py) == 1,
        format("a cursor left of the press column must floor at one pass; got %d",
               passesAt(px - 40, py)));

    // Out and back: rising on the way out, and back to a single pass once the
    // cursor returns to the press column — the count follows the CURRENT
    // offset, never the distance travelled.
    assert(passesAt(px + 100, py) == 21, "a +100px offset is 21 passes");
    assert(passesAt(px, py) == 1, "returning to the press column returns to one pass");

    SDL_MouseButtonEvent eUp;
    eUp.button = SDL_BUTTON_LEFT;
    eUp.x = px; eUp.y = py;
    assert(t.onMouseButtonUp(eUp, vts), "LMB-up must be consumed");
    assert(!t.smoothArmed_, "release must disarm Smooth");

    // A fresh press re-anchors: the offset is measured from the NEW press
    // pixel, so nothing accumulates across gestures.
    SDL_MouseButtonEvent eDown2;
    eDown2.button = SDL_BUTTON_LEFT;
    eDown2.x = px + 500; eDown2.y = py;
    assert(t.onMouseButtonDown(eDown2, vts), "a second Shift+Ctrl+LMB press must arm again");
    assert(cast(int)t.toolStateJson()["smoothPassCount"].integer == 1,
        "a fresh press must start over at one pass — the count never survives a gesture");

    SDL_SetModState(cast(SDL_Keymod)0);   // leave the shared SDL modifier global clean
}

// ---------------------------------------------------------------------------
// applySmoothPasses — T7 (P8 REV1 FIX-2, doc/topopen_p8_smooth_plan.md): a
// Smooth gesture over a fully DISCONNECTED patch (every vertex has 0
// neighbors) with NO background source is the ROUTINE no-op case — the
// mesh must be byte-identical and record NO undo entry, mirroring
// `commitSlide`'s own T5c both-fixed no-op test. `gpu_` stays null and this
// path returns before ever reaching `refreshDisplay` — safe under bare
// `dub test`.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import snap : setBackgroundSnapSources;

    // Defensive (test-isolation, not a production call site): `snap.d`'s
    // background-source list is a module-level `__gshared` — explicitly
    // clear it rather than assume no earlier `dub test` unittest left it
    // populated, so this test's "no background source" premise holds
    // regardless of run order.
    setBackgroundSnapSources(null, null);

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_           = history;
    t.smoothEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                     "mesh.topoPen_smooth", "Topology Smooth",
                                                     MeshEditScope.Position);

    Mesh m;
    t.meshSrc_ = () => &m;
    m.addVertex(Vec3(0, 0, 0));
    m.addVertex(Vec3(5, 0, 0));
    m.addVertex(Vec3(0, 5, 0));   // 3 isolated points -> 0 neighbors each, no background layer

    auto before = MeshSnapshot.capture(m);
    t.applySmoothPasses(1);
    auto after = MeshSnapshot.capture(m);

    assert(after.vertices == before.vertices,
        "a disconnected patch with no background source must be a byte-identical no-op");
    assert(!history.canUndo(),
        "a disconnected/no-bg Smooth gesture must record NO undo entry");
}

// ---------------------------------------------------------------------------
// applySmoothPasses — isolated (0-neighbor) vertex WITH a background present
// (review NIT-2): T7 above only covers "no background source at all". This
// covers the previously-untested combination — a loose point plus a LIVE
// background layer — which used to fall through to the `sources.length`
// re-snap branch and get pulled onto the background surface even though it
// has zero relaxation neighbors, contradicting the FIX-2 "0-neighbor = true
// no-op" premise (and this behavior was never measured against the
// reference — a deliberate NON-goal, not a modeled law). The fix skips a
// 0-neighbor vertex entirely, so it stays byte-unchanged regardless of
// whether a background exists; since it is the ONLY vertex here, the whole
// gesture nets to no-op and records no undo entry either. `gpu_` stays
// null and this path returns before ever reaching `refreshDisplay` — safe
// under bare `dub test`.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import snap : setBackgroundSnapSources;

    auto bg = new Mesh();
    bg.vertices = [Vec3(-10, -10, -5), Vec3(10, -10, -5), Vec3(10, 10, -5), Vec3(-10, 10, -5)];
    bg.faces    = [[0u, 1u, 2u, 3u]];
    const(Mesh)*[] srcs = [cast(const(Mesh)*) bg];
    import math : ModelSpace;
    setBackgroundSnapSources(srcs, new ModelSpace[](srcs.length));
    scope(exit) setBackgroundSnapSources(null, null);   // don't leak into later dub-test unittests

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_           = history;
    t.smoothEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                     "mesh.topoPen_smooth", "Topology Smooth",
                                                     MeshEditScope.Position);

    Mesh m;
    t.meshSrc_ = () => &m;
    m.addVertex(Vec3(0, 0, 0));   // single isolated point -> 0 neighbors, background IS present

    auto before = MeshSnapshot.capture(m);
    t.applySmoothPasses(1);
    auto after = MeshSnapshot.capture(m);

    assert(after.vertices == before.vertices,
        "an isolated (0-neighbor) vertex must stay byte-unchanged even WITH a background "
      ~ "present — loose points are never snapped to a surface");
    assert(!history.canUndo(),
        "the only vertex in the gesture is untouched -> no undo entry, even with a background");
}

// ---------------------------------------------------------------------------
// applySmoothPasses — LOW STRENGTH x SMALL EDGES must still produce a
// visible, undoable change (review SHOULD-FIX: the no-op guard was an
// ABSOLUTE 1e-4 world-unit threshold).
//
// This pins the exact combination that used to be swallowed. Smooth's
// displacement is not drag-proportional — it scales with mesh size and with
// `smoothStrength` — so a fixed threshold creates a silent cliff below which
// the whole gesture is discarded: mesh restored, no undo entry, no feedback.
// The rig is an irregular hexahedron with 0.07-unit edges (ordinary
// detail-modelling scale, and the spacing of the reference capture rig) at
// strength 0.05, which is legal and well inside the Param's own [0, 4].
//
// The middle assertion is the one that makes this a REGRESSION test rather
// than a generic smoke test: it asserts the movement is genuinely BELOW the
// old 1e-4 constant. So the rig provably lands in the swallowed band, and
// this test would fail against the previous guard rather than passing for
// unrelated reasons. `gpu_` stays null, so `refreshDisplay` is never reached
// — safe under bare `dub test`.
// ---------------------------------------------------------------------------
unittest {
    import std.format : format;
    import view : View;
    import editmode : EditMode;
    import snap : setBackgroundSnapSources;

    setBackgroundSnapSources(null, null);   // no background — isolate pure relaxation

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_           = history;
    t.smoothEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                     "mesh.topoPen_smooth", "Topology Smooth",
                                                     MeshEditScope.Position);

    // Irregular hexahedron (one corner pulled out so it is NOT a fixed point
    // of the relaxation law), scaled to 0.07-unit edges.
    enum float s = 0.035f;
    Mesh m;
    t.meshSrc_ = () => &m;
    foreach (p; [Vec3(-1, -1, -1), Vec3(1, -1, -1), Vec3(1, 1, -1), Vec3(-1, 1, -1),
                 Vec3(-1, -1,  1), Vec3(1, -1,  1), Vec3(1.8, 1.3, 1.1), Vec3(-1, 1, 1)])
        m.addVertex(p * s);
    m.addFace([0u, 3u, 2u, 1u]);  m.addFace([4u, 5u, 6u, 7u]);
    m.addFace([0u, 1u, 5u, 4u]);  m.addFace([2u, 3u, 7u, 6u]);
    m.addFace([1u, 2u, 6u, 5u]);  m.addFace([0u, 4u, 7u, 3u]);
    m.buildLoops();

    t.smoothStrength_ = 0.05f;   // legal, inside the Param's declared [0, 4]

    auto before = MeshSnapshot.capture(m);
    t.applySmoothPasses(1);      // one click == one iteration

    float maxDisp = 0;
    foreach (i; 0 .. m.vertices.length) {
        immutable float d = (m.vertices[i] - before.vertices[i]).length;
        if (d > maxDisp) maxDisp = d;
    }

    assert(maxDisp > 0,
        "setup: an irregular mesh must genuinely relax — a regular one is an exact fixed "
      ~ "point of this law and would make the assertions below vacuous");
    assert(maxDisp < 1e-4f,
        format("setup: this rig must land in the band the OLD absolute 1e-4 guard swallowed, "
             ~ "or it is not testing the regression; maxDisp=%.4e", maxDisp));
    assert(history.canUndo(),
        format("a low-strength gesture on a small-scale mesh must still be recorded as a real, "
             ~ "undoable edit — the no-op threshold must scale with the model, not sit at a "
             ~ "fixed world-unit constant (maxDisp=%.4e)", maxDisp));

    // ...and the movement must have SURVIVED, not been rolled back by the
    // guard: `before.restore` on the no-op path would leave these identical.
    bool anyMoved = false;
    foreach (i; 0 .. m.vertices.length)
        if (m.vertices[i] != before.vertices[i]) { anyMoved = true; break; }
    assert(anyMoved,
        "the relaxed positions must remain in the mesh — a swallowed gesture restores "
      ~ "`before` and leaves every vertex byte-identical");
}

// ---------------------------------------------------------------------------
// buildRelaxTopology — boundary-restriction coverage (review NIT-4, carried
// forward to the current kernel): the conformance fixture above pins the
// restriction NUMERICALLY (dropping it costs 4.3e-02 there), but only as one
// term inside a whole-mesh result. This isolates the extraction itself on a
// rig where boundary vertex `v0` has BOTH kinds of neighbor at once:
// `v1`/`v3` via open (single-face) edges, `v2` via the edge shared by both
// triangles. A regression that dropped the exclusion would still reproduce
// every other structural property and fail here.
//
// Asserted against `buildRelaxTopology`'s OWN output — the per-slot `openTo`
// flags and the derived per-vertex `boundary` flag — rather than against a
// relaxed position, so the failure points at the extraction rather than at
// the arithmetic downstream of it.
// ---------------------------------------------------------------------------
unittest {
    import std.format : format;

    Mesh m;
    uint v0 = m.addVertex(Vec3(0, 0, 0));
    uint v1 = m.addVertex(Vec3(1, 0, 0));    // open-edge neighbor  (v0-v1: face0 only)
    uint v2 = m.addVertex(Vec3(10, 10, 0));  // INTERIOR neighbor   (v0-v2: shared by both faces)
    uint v3 = m.addVertex(Vec3(0, 1, 0));    // open-edge neighbor  (v0-v3: face1 only)
    m.addFace([v0, v1, v2]);
    m.addFace([v0, v2, v3]);
    m.buildLoops();

    // Rig sanity: v0-v2 must actually be the shared (interior) edge, and v0
    // must actually classify as a boundary vertex, or this rig isn't
    // testing what it claims to.
    uint eV0V2 = m.edgeIndex(v0, v2);
    assert(eV0V2 != uint.max, "setup: v0-v2 must exist as an edge");
    assert(!TopologyPenTool.isOpenEdge(&m, eV0V2),
        "setup: v0-v2 must be INTERIOR (shared by both faces) for this rig to test anything");
    const(size_t)[] adjOff;
    const(uint)[]   adjNbrs;
    m.vertexAdjacencyCSR(adjOff, adjNbrs);
    assert(TopologyPenTool.isOpenVertex(&m, v0, adjOff, adjNbrs),
        "setup: v0 must classify as a boundary vertex (has open edges v0-v1/v0-v3)");

    auto topo = TopologyPenTool.buildRelaxTopology(&m);
    assert(topo.valid(m.vertices.length), "extracted topology must be self-consistent");
    assert(topo.boundary[v0],
        "v0 has open incident edges — the derived boundary flag must be set, which is what "
      ~ "restricts its relaxation neighbor set");

    // The restriction that flag triggers: exactly v1 and v3 survive for v0,
    // and the interior neighbor v2 is excluded.
    bool sawV1, sawV2, sawV3;
    foreach (k; topo.offset[v0] .. topo.offset[v0 + 1]) {
        immutable uint nb = topo.nbrs[k];
        if (nb == v1) { sawV1 = true; assert(topo.openTo[k], "v0-v1 is a single-face edge — must be OPEN"); }
        if (nb == v3) { sawV3 = true; assert(topo.openTo[k], "v0-v3 is a single-face edge — must be OPEN"); }
        if (nb == v2) {
            sawV2 = true;
            assert(!topo.openTo[k],
                format("v0-v2 is shared by both faces — it must NOT be flagged open, or the "
                     ~ "interior neighbor leaks into boundary vertex v0's relaxation set"));
        }
    }
    assert(sawV1 && sawV2 && sawV3, "setup: v0's CSR ring must contain all three neighbors");

    // v2 itself is also a boundary vertex here (its v2-v1 / v2-v3 rim edges
    // are single-face), so the flag is not vacuously true for v0 alone.
    assert(topo.boundary[v1] && topo.boundary[v2] && topo.boundary[v3],
        "every vertex of this two-triangle patch sits on the rim");
}

// ---------------------------------------------------------------------------
// commitSplit — T1 (P9, doc/topopen_p9_split_plan.md §Testing): QUAD
// diagonal split (v0->v2). Independent expected — cross-checked against
// `mesh.d`'s own `splitFaceByVertices` unittest, but
// re-derived here rather than re-asserted, since `commitSplit` is the thing
// under test (the snapshot/undo bracket + factory wiring around the kernel
// call, not the kernel itself).
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_          = history;
    t.splitEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                    "mesh.topoPen_split", "Topology Split",
                                                    MeshEditScope.Geometry);

    Mesh m;
    t.meshSrc_ = () => &m;

    m.addVertex(Vec3(0, 0, 0));   // 0
    m.addVertex(Vec3(1, 0, 0));   // 1
    m.addVertex(Vec3(1, 1, 0));   // 2
    m.addVertex(Vec3(0, 1, 0));   // 3
    m.addFace([0u, 1u, 2u, 3u]);
    m.buildLoops();

    t.commitSplit(0, 2);

    assert(m.faces.length == 2, "commitSplit: expected 2 faces after a quad diagonal split");
    assert(m.edges.length == 5, "commitSplit: expected 5 edges (4 boundary + 1 chord)");
    bool hasF1 = false, hasF2 = false;
    foreach (f; m.faces) {
        if (f[] == [0u, 1u, 2u]) hasF1 = true;
        if (f[] == [2u, 3u, 0u]) hasF2 = true;
    }
    assert(hasF1, "commitSplit: expected face [0,1,2]");
    assert(hasF2, "commitSplit: expected face [2,3,0]");
    assert(m.vertices.length == 4, "commitSplit: split is Δv=0 — no vertex is added");
    assert(history.canUndo(), "a real split must record one undo entry");
}

// ---------------------------------------------------------------------------
// commitSplit — T2 (P9, doc/topopen_p9_split_plan.md §Testing): HEXAGON
// non-adjacent split (v0->v3), proving the split isn't quad-only.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_          = history;
    t.splitEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                    "mesh.topoPen_split", "Topology Split",
                                                    MeshEditScope.Geometry);

    Mesh m;
    t.meshSrc_ = () => &m;

    m.addVertex(Vec3( 2.0f,  0.0f,    0));   // 0
    m.addVertex(Vec3( 1.0f,  1.732f,  0));   // 1
    m.addVertex(Vec3(-1.0f,  1.732f,  0));   // 2
    m.addVertex(Vec3(-2.0f,  0.0f,    0));   // 3
    m.addVertex(Vec3(-1.0f, -1.732f,  0));   // 4
    m.addVertex(Vec3( 1.0f, -1.732f,  0));   // 5
    m.addFace([0u, 1u, 2u, 3u, 4u, 5u]);
    m.buildLoops();

    assert(m.vertices.length == 6 && m.edges.length == 6 && m.faces.length == 1,
        "setup: pre-state must be the hand-enumerated hexagon (6v/6e/1f)");

    t.commitSplit(0, 3);

    assert(m.faces.length == 2, "commitSplit: expected 2 faces after a hexagon non-adjacent split");
    assert(m.edges.length == 7, "commitSplit: expected 7 edges (6 boundary + 1 chord)");
    bool hasF1 = false, hasF2 = false;
    foreach (f; m.faces) {
        if (f[] == [0u, 1u, 2u, 3u]) hasF1 = true;
        if (f[] == [3u, 4u, 5u, 0u]) hasF2 = true;
    }
    assert(hasF1, "commitSplit: expected face [0,1,2,3]");
    assert(hasF2, "commitSplit: expected face [3,4,5,0]");
    assert(m.vertices.length == 6, "commitSplit: split is Δv=0 — no vertex is added");
    assert(history.canUndo(), "a real split must record one undo entry");
}

// ---------------------------------------------------------------------------
// commitSplit — T3 (P9, doc/topopen_p9_split_plan.md §Testing): adjacent A/C
// (chord would duplicate an existing edge) must be a byte-identical no-op —
// no mutation, no undo entry.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_          = history;
    t.splitEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                    "mesh.topoPen_split", "Topology Split",
                                                    MeshEditScope.Geometry);

    Mesh m;
    t.meshSrc_ = () => &m;
    m.addVertex(Vec3(0, 0, 0));
    m.addVertex(Vec3(1, 0, 0));
    m.addVertex(Vec3(1, 1, 0));
    m.addVertex(Vec3(0, 1, 0));
    m.addFace([0u, 1u, 2u, 3u]);
    m.buildLoops();

    auto before = MeshSnapshot.capture(m);
    t.commitSplit(0, 1);   // adjacent (standard, not wrap)
    t.commitSplit(3, 0);   // adjacent (wrap-around)
    auto after = MeshSnapshot.capture(m);

    assert(after.vertices == before.vertices && after.edges == before.edges
        && after.faces == before.faces, "adjacent A/C must not mutate the mesh");
    assert(!history.canUndo(), "adjacent A/C must record NO undo entry");
}

// ---------------------------------------------------------------------------
// commitSplit — T4 (P9, doc/topopen_p9_split_plan.md §Testing): A==C must be
// a byte-identical no-op.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_          = history;
    t.splitEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                    "mesh.topoPen_split", "Topology Split",
                                                    MeshEditScope.Geometry);

    Mesh m;
    t.meshSrc_ = () => &m;
    m.addVertex(Vec3(0, 0, 0));
    m.addVertex(Vec3(1, 0, 0));
    m.addVertex(Vec3(1, 1, 0));
    m.addVertex(Vec3(0, 1, 0));
    m.addFace([0u, 1u, 2u, 3u]);
    m.buildLoops();

    auto before = MeshSnapshot.capture(m);
    t.commitSplit(0, 0);
    auto after = MeshSnapshot.capture(m);

    assert(after.vertices == before.vertices && after.edges == before.edges
        && after.faces == before.faces, "A==C must not mutate the mesh");
    assert(!history.canUndo(), "A==C must record NO undo entry");
}

// ---------------------------------------------------------------------------
// commitSplit — T6 (task 0489): the split LAW as it was measured live, rather
// than as it was reasoned about.
//
// Two chord cells committed under instrumentation with every gate value read
// out of the reference engine on the way through, and both produced the same
// three-part signature:
//
//     Δ(V,E,F) = (0, +1, +1),  max|dp| = 0,  exactly ONE undo restores both
//     the counts and the positions.
//
// The vertex count is the load-bearing third of that: a chord split adds no
// vertex, so a kernel that ever grew `vertices` would be wrong even with the
// right face count. `max|dp| = 0` is the fourth: a split never moves geometry.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_          = history;
    t.splitEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                    "mesh.topoPen_split", "Topology Split",
                                                    MeshEditScope.Geometry);

    Mesh m;
    t.meshSrc_ = () => &m;
    // the measured rig: a regular hexagon, one polygon
    foreach (i; 0 .. 6) {
        import std.math : cos, sin, PI;
        const float th = cast(float)(PI / 2.0 - 2.0 * PI * i / 6.0);
        m.addVertex(Vec3(2.0f * cos(th), 2.0f * sin(th), 0));
    }
    m.addFace([0u, 1u, 2u, 3u, 4u, 5u]);
    m.buildLoops();

    auto before = MeshSnapshot.capture(m);
    const size_t v0 = m.vertices.length, e0 = m.edges.length, f0 = m.faces.length;

    t.commitSplit(0, 2);   // the measured cell: press v0, release v2

    assert(m.vertices.length == v0, "measured law: a chord split is Δv = 0");
    assert(m.edges.length == e0 + 1, "measured law: a chord split is Δe = +1");
    assert(m.faces.length == f0 + 1, "measured law: a chord split is Δf = +1");

    // no vertex moves — measured as max|dp| = 0 on every committing cell
    auto after = MeshSnapshot.capture(m);
    assert(after.vertices[0 .. v0] == before.vertices[0 .. v0],
        "measured law: a chord split never moves existing geometry");

    // ONE undo restores counts AND positions (measured: undo_steps == 1)
    assert(history.canUndo(), "a real split records exactly one undo entry");
    history.undo();
    assert(m.vertices.length == v0 && m.edges.length == e0
        && m.faces.length == f0,
        "measured law: ONE undo restores the counts");
    assert(MeshSnapshot.capture(m).vertices == before.vertices,
        "measured law: ONE undo restores the positions");
    assert(!history.canUndo(), "the split must be ONE undo entry, not two");
}

// ---------------------------------------------------------------------------
// commitSplit — T7 (task 0489): the GATE EQUIVALENCE, proven exhaustively
// instead of argued in a comment.
//
// The reference refuses a chord through four separate tests. Three of them are
// redundant: with `n1 = ((j - i) mod n) + 1` and `n2 = n - n1 + 2`, the pair
// `n1 >= 3 && n2 >= 3` is equivalent to `2 <= (j - i) mod n <= n - 2`, which is
// exactly "distinct, and not neighbours around the ring"; the `|i - j| >= 2`
// test is strictly implied by it, and the `n >= 4` test is implied for a
// triangle. So the whole law is ONE clause, and it is the clause
// `findCommonSplitFace` already spells as `adjacent`.
//
// This asserts that equality over every polygon size and every ordered pair,
// so the claim stops depending on anyone re-reading the argument.
// ---------------------------------------------------------------------------
unittest {
    foreach (n; 3 .. 13) {
        foreach (i; 0 .. n) {
            foreach (j; 0 .. n) {
                // our clause, written exactly as findCommonSplitFace has it
                const int lo = i < j ? i : j;
                const int hi = i < j ? j : i;
                const bool ours = !(i == j)
                    && !((hi == lo + 1) || (lo == 0 && hi == n - 1));

                // the reference's four tests, in its own arithmetic
                const int n1 = ((j - i) % n + n) % n + 1;
                const int n2 = n - n1 + 2;
                const bool theirs = (n >= 4)
                    && (i > j ? i - j : j - i) >= 2
                    && n1 >= 3 && n2 >= 3;

                assert(ours == theirs,
                    "gate equivalence broken: our adjacency reject and the "
                    ~ "reference's four gates must accept exactly the same "
                    ~ "(polygon size, corner pair) set");
            }
        }
    }
}

// ---------------------------------------------------------------------------
// commitSplit — T8 (task 0489): divergence D1, the NON-MANIFOLD fork.
//
// MEASURED: on a rig where the same vertex pair is a legal chord of one
// incident polygon and an illegal one of another, the reference resolves
// EXACTLY ONE candidate, finds it unsuitable, and abandons the split — it does
// not try the other polygon. Δ = (0,0,0), with the engine printing
// `nverts = 3` for the candidate it picked.
//
// vibe3d deliberately does the opposite: `findCommonSplitFace` walks the
// pressed vertex's faces and `continue`s past a failing candidate to the next
// one, so it finds the quad and cuts. The retry is defended on purpose by the
// REV1 FIX-3 comment above that function.
//
// This test pins OUR behaviour and NAMES it as the measured divergence, so the
// day someone decides to match the reference this assertion is the thing that
// tells them the change is intentional rather than a regression.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_          = history;
    t.splitEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                    "mesh.topoPen_split", "Topology Split",
                                                    MeshEditScope.Geometry);

    Mesh m;
    t.meshSrc_ = () => &m;
    m.addVertex(Vec3(1, -1, 0));   // 0
    m.addVertex(Vec3(-1, -1, 0));  // 1
    m.addVertex(Vec3(-1, 1, 0));   // 2
    m.addVertex(Vec3(1, 1, 0));    // 3
    m.addFace([0u, 1u, 2u]);       // the triangle: (0,2) is ADJACENT here
    m.addFace([0u, 1u, 2u, 3u]);   // the quad:     (0,2) is a legal chord here
    m.buildLoops();

    const size_t f0 = m.faces.length;
    t.commitSplit(0, 2);

    // DIVERGENCE D1, deliberate and now measured: the reference refuses here
    // (one candidate, no retry); we retry and cut.
    assert(m.faces.length == f0 + 1,
        "D1: vibe3d retries past the unsuitable candidate and splits the quad "
        ~ "-- the reference resolves one candidate and refuses. If this "
        ~ "assertion is being changed, the change is a deliberate move TOWARD "
        ~ "the reference, not a regression.");
    assert(m.vertices.length == 4, "D1: the split still adds no vertex");
}

// ---------------------------------------------------------------------------
// commitSplit — T9 (task 0489): divergence D2, WHICH HALF KEEPS THE PARENT
// POLYGON'S SLOT.
//
// MEASURED, on the one case shape that can tell the two conventions apart —
// a chord whose PRESS index is the HIGHER winding index. The reference keeps
// the arc running from the PRESSED vertex forward to the RELEASED one in the
// parent's slot, and appends the mirror arc as the new polygon. vibe3d's
// `rebuildFacesWithChordSplits` takes `f1 = face[i .. j+1]` with `i` the LOWER
// winding index regardless of which end was pressed, so the two halves are
// SWAPPED whenever `idx(press) > idx(release)`.
//
// The counts are identical either way, which is why this went unnoticed: only
// the face identity differs, and today both halves inherit the same per-face
// attributes, so the divergence is visible only through the facet index and
// anything keyed on it.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_          = history;
    t.splitEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                    "mesh.topoPen_split", "Topology Split",
                                                    MeshEditScope.Geometry);

    Mesh m;
    t.meshSrc_ = () => &m;
    foreach (i; 0 .. 6) {
        import std.math : cos, sin, PI;
        const float th = cast(float)(PI / 2.0 - 2.0 * PI * i / 6.0);
        m.addVertex(Vec3(2.0f * cos(th), 2.0f * sin(th), 0));
    }
    m.addFace([0u, 1u, 2u, 3u, 4u, 5u]);
    m.buildLoops();

    // REVERSED chord: press v3, release v0 -> idx(press) 3 > idx(release) 0
    t.commitSplit(3, 0);
    assert(m.faces.length == 2 && m.edges.length == 7 && m.vertices.length == 6,
        "D2 setup: the reversed chord must still split (0,+1,+1)");

    // OUR convention: the parent slot (face index 0) keeps the LOW-index arc.
    assert(m.faces[0][] == [0u, 1u, 2u, 3u],
        "D2: vibe3d keeps the LOW-index arc in the parent slot. MEASURED, the "
        ~ "reference keeps the arc from the PRESSED vertex ([3,4,5,0] here) "
        ~ "and appends [0,1,2,3]. The halves are swapped whenever the press "
        ~ "index is the higher one. Changing this assertion to [3,4,5,0] is "
        ~ "the fix that closes D2 -- it is an owner call because it moves a "
        ~ "shipped facet index.");
    assert(m.faces[1][] == [3u, 4u, 5u, 0u],
        "D2: and the new polygon is the other arc");

    // the FORWARD chord is where the two conventions agree -- kept here so the
    // test itself documents why a forward-chord case can never discriminate
    Mesh m2;
    t.meshSrc_ = () => &m2;
    foreach (i; 0 .. 6) {
        import std.math : cos, sin, PI;
        const float th = cast(float)(PI / 2.0 - 2.0 * PI * i / 6.0);
        m2.addVertex(Vec3(2.0f * cos(th), 2.0f * sin(th), 0));
    }
    m2.addFace([0u, 1u, 2u, 3u, 4u, 5u]);
    m2.buildLoops();
    t.commitSplit(0, 3);
    assert(m2.faces[0][] == [0u, 1u, 2u, 3u],
        "D2 control: on a FORWARD chord both conventions give the same parent "
        ~ "slot, which is why every earlier case was blind to the difference");
}

// ---------------------------------------------------------------------------
// commitSplit — T5 (P9, doc/topopen_p9_split_plan.md §Testing): a release
// that does not land on a vertex (C == -1) must be a byte-identical no-op.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_          = history;
    t.splitEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                    "mesh.topoPen_split", "Topology Split",
                                                    MeshEditScope.Geometry);

    Mesh m;
    t.meshSrc_ = () => &m;
    m.addVertex(Vec3(0, 0, 0));
    m.addVertex(Vec3(1, 0, 0));
    m.addVertex(Vec3(1, 1, 0));
    m.addVertex(Vec3(0, 1, 0));
    m.addFace([0u, 1u, 2u, 3u]);
    m.buildLoops();

    auto before = MeshSnapshot.capture(m);
    t.commitSplit(0, -1);
    auto after = MeshSnapshot.capture(m);

    assert(after.vertices == before.vertices && after.edges == before.edges
        && after.faces == before.faces, "release-not-on-vertex must not mutate the mesh");
    assert(!history.canUndo(), "release-not-on-vertex must record NO undo entry");
}

// ---------------------------------------------------------------------------
// commitSplit — T6 (P9, doc/topopen_p9_split_plan.md §Testing): A and C on
// two DISJOINT faces (no shared polygon at all) must be a byte-identical
// no-op.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_          = history;
    t.splitEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                    "mesh.topoPen_split", "Topology Split",
                                                    MeshEditScope.Geometry);

    Mesh m;
    t.meshSrc_ = () => &m;
    m.addVertex(Vec3(0, 0, 0));   // 0 (F0)
    m.addVertex(Vec3(1, 0, 0));   // 1 (F0)
    m.addVertex(Vec3(1, 1, 0));   // 2 (F0)
    m.addVertex(Vec3(0, 1, 0));   // 3 (F0)
    m.addVertex(Vec3(5, 0, 0));   // 4 (F1)
    m.addVertex(Vec3(6, 0, 0));   // 5 (F1)
    m.addVertex(Vec3(6, 1, 0));   // 6 (F1)
    m.addVertex(Vec3(5, 1, 0));   // 7 (F1)
    m.addFace([0u, 1u, 2u, 3u]);
    m.addFace([4u, 5u, 6u, 7u]);
    m.buildLoops();

    auto before = MeshSnapshot.capture(m);
    t.commitSplit(0, 4);   // v0 in F0, v4 in F1 -> no common face
    auto after = MeshSnapshot.capture(m);

    assert(after.vertices == before.vertices && after.edges == before.edges
        && after.faces == before.faces, "cross-polygon A/C must not mutate the mesh");
    assert(!history.canUndo(), "cross-polygon A/C must record NO undo entry");
}

// ---------------------------------------------------------------------------
// findCommonSplitFace / commitSplit — T7 (P9 REV1 FIX-3, MODERATE): two
// faces share A(0) and C(1) — a TRIANGLE where A-C is a real WRAP-AROUND
// edge (A at the LAST winding position, C at the FIRST — the exact case an
// UNSORTED `i=posA,j=posC` adjacency check evades: `j==i+1` is false
// (0 != 2+1) and `i==0&&j==len-1` is false (i=2 != 0), so an unfixed version
// would wrongly treat this face as non-adjacent) and a PENTAGON where A and
// C are genuinely non-adjacent (splittable). The two faces are wired to
// share edge A-D so `facesAroundVertex(A)` walks BOTH via the dart fan (a
// setup sanity check below pins that this rig actually exercises the
// tie-break, rather than one face being unreachable). The FIXED
// (sorted-lo/hi) implementation must SKIP the triangle and split the
// pentagon; the buggy unsorted version would return the triangle first,
// the kernel would then correctly reject it (real edge) and return 0, and
// `commitSplit` would silently no-op — losing the legitimate pentagon split
// this test pins.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_          = history;
    t.splitEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                    "mesh.topoPen_split", "Topology Split",
                                                    MeshEditScope.Geometry);

    Mesh m;
    t.meshSrc_ = () => &m;
    // A=0, C=1, D=2, E=3, F=4
    foreach (i; 0 .. 5) m.addVertex(Vec3(cast(float)i, 0, 0));
    m.addFace([1u, 2u, 0u]);          // face0: triangle [C,D,A] -> A@pos2(len-1), C@pos0 (wrap-adjacent)
    m.addFace([0u, 2u, 3u, 1u, 4u]);  // face1: pentagon [A,D,E,C,F] -> A@pos0, C@pos3 (non-adjacent)
                                       // shares edge A-D with face0, so both
                                       // faces are on A's dart fan.
    m.buildLoops();

    // Setup sanity: `facesAroundVertex(A)` must actually enumerate BOTH
    // faces, or this rig isn't testing the tie-break at all (it would just
    // be testing "the only reachable face wins").
    int incidentCount = 0;
    foreach (fi; m.facesAroundVertex(0u)) ++incidentCount;
    assert(incidentCount == 2,
        "setup: vertex A(0) must be incident to BOTH the triangle and the pentagon");

    auto triangleBefore = m.faces[0].dup;

    t.commitSplit(0, 1);

    assert(m.faces.length == 3,
        "expected the PENTAGON to split into 2 sub-faces (triangle survives untouched) -- "
      ~ "3 total faces");
    bool triangleSurvives = false;
    foreach (f; m.faces) if (f[] == triangleBefore[]) triangleSurvives = true;
    assert(triangleSurvives,
        "the adjacent triangle (where A-C is a real edge) must survive byte-unchanged -- "
      ~ "the tool must have picked the PENTAGON, not the triangle");
    assert(history.canUndo(), "the pentagon split must be a real, undoable mutation");
}

// ---------------------------------------------------------------------------
// findCommonSplitFace / commitSplit — T7b (P9 REVIEW NIT-1, vacuous-pass
// hazard): T7 above pins the FIX-3 sorted-lo/hi tie-break, but it only
// EXERCISES the tie-break if `facesAroundVertex(A)`'s dart fan visits the
// triangle (the must-be-rejected face) before the pentagon -- T7 does not
// pin that ordering. `buildLoops`'s serial `vertLoop` seed pass is
// last-write-wins over increasing loop index (face-major order), so the
// face added LAST at the shared vertex is the one the fan visits FIRST; in
// T7 (triangle added, then pentagon) that means the pentagon is visited
// first and `findCommonSplitFace` returns it before the triangle's
// adjacency check is ever reached -- an unsorted-variant regression would
// ALSO pass T7, vacuously. This rig is IDENTICAL to T7 except the two
// `addFace` calls are swapped, flipping which face is added last so the
// triangle is visited first instead. Together the two tests guarantee the
// triangle is first-in-fan in at least one of them, so the pair catches an
// unsorted-variant regression regardless of fan-walk order.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_          = history;
    t.splitEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                    "mesh.topoPen_split", "Topology Split",
                                                    MeshEditScope.Geometry);

    Mesh m;
    t.meshSrc_ = () => &m;
    // A=0, C=1, D=2, E=3, F=4 -- same rig as T7, `addFace` calls SWAPPED
    // (pentagon first, triangle second) so the triangle is added last.
    foreach (i; 0 .. 5) m.addVertex(Vec3(cast(float)i, 0, 0));
    m.addFace([0u, 2u, 3u, 1u, 4u]);  // pentagon [A,D,E,C,F] -> A@pos0, C@pos3 (non-adjacent)
    m.addFace([1u, 2u, 0u]);          // triangle [C,D,A] -> A@pos2(len-1), C@pos0 (wrap-adjacent)
                                       // shares edge A-D with the pentagon, so both
                                       // faces are on A's dart fan.
    m.buildLoops();

    // Setup sanity: same as T7, plus this rig's whole POINT -- the triangle
    // (not the pentagon) must be first-in-fan here, the opposite of T7.
    int incidentCount = 0;
    int firstFi = -1;
    foreach (fi; m.facesAroundVertex(0u)) { if (firstFi < 0) firstFi = cast(int)fi; ++incidentCount; }
    assert(incidentCount == 2,
        "setup: vertex A(0) must be incident to BOTH the triangle and the pentagon");
    assert(m.faces[firstFi].length == 3,
        "setup: this rig must visit the TRIANGLE first in A's dart fan (the opposite of T7) -- "
      ~ "otherwise it duplicates T7 instead of covering the flipped order");

    int triangleFi = (m.faces[0].length == 3) ? 0 : 1;
    auto triangleBefore = m.faces[triangleFi].dup;

    t.commitSplit(0, 1);

    assert(m.faces.length == 3,
        "expected the PENTAGON to split into 2 sub-faces (triangle survives untouched) -- "
      ~ "3 total faces");
    bool triangleSurvives = false;
    foreach (f; m.faces) if (f[] == triangleBefore[]) triangleSurvives = true;
    assert(triangleSurvives,
        "the adjacent triangle (where A-C is a real edge) must survive byte-unchanged -- "
      ~ "the tool must have picked the PENTAGON, not the triangle, even when the triangle "
      ~ "is visited FIRST in the dart fan");
    assert(history.canUndo(), "the pentagon split must be a real, undoable mutation");
}

// ---------------------------------------------------------------------------
// commitSplit — T8 (P9, doc/topopen_p9_split_plan.md §Testing): a real split
// must undo back to the exact pre-split state.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_          = history;
    t.splitEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                    "mesh.topoPen_split", "Topology Split",
                                                    MeshEditScope.Geometry);

    Mesh m;
    t.meshSrc_ = () => &m;
    m.addVertex(Vec3(0, 0, 0));
    m.addVertex(Vec3(1, 0, 0));
    m.addVertex(Vec3(1, 1, 0));
    m.addVertex(Vec3(0, 1, 0));
    m.addFace([0u, 1u, 2u, 3u]);
    m.buildLoops();

    auto before = MeshSnapshot.capture(m);
    t.commitSplit(0, 2);
    assert(history.canUndo(), "a real split must be undoable");
    history.undo();
    auto after = MeshSnapshot.capture(m);

    assert(after.vertices == before.vertices && after.edges == before.edges
        && after.faces == before.faces,
        "undo must restore the exact pre-split state");
}

// ---------------------------------------------------------------------------
// onMouseButtonDown / onMouseButtonUp — MANDATORY DISPATCH (P9 REV1 FIX-2,
// doc/topopen_p9_split_plan.md): drives the REAL dispatch path directly —
// `onMouseButtonDown` (plain MMB -> `onPlainMmbDown`) and `onMouseButtonUp`
// (the restructured MIDDLE branch -> `commitSplit`) — rather than calling
// `commitSplit` directly as the 8 Tier-B cases above do. Those 8 cases
// exercise the MUTATION but bypass dispatch entirely, so they would NOT
// have caught the pre-FIX-2 shape (`if (!addLoopArmed_) return false; ...`)
// that made a `splitArmed_` check placed after it categorically
// unreachable. Also pins the guard-structure sanity FIX-2 calls for
// separately: `onMouseButtonDown`'s MIDDLE routing must send a Ctrl/Shift
// chord to Remove/Add Loop, never to Split.
//
// SDL's dynamic bindings must be resolved before any real `SDL_GetModState`/
// `SDL_SetModState` call (`onMouseButtonDown` reads the LIVE modifier state
// internally) — under a bare `dub test`, app.d's own `loadSDL()` (called
// from `main()`, which never runs before unittests execute) has NOT run
// yet; calling an unresolved dynamic SDL function segfaults. `loadSDL()`
// itself needs no `SDL_Init`/video subsystem — `SDL_GetModState`/
// `SDL_SetModState` are plain global-variable accessors in the real SDL2
// library, safe to call the moment the dynamic symbols are resolved, and
// `loadSDL()` is idempotent (safe to call more than once across unittests).
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import toolpipe.packets : SubjectPacket;

    loadSDL();
    SDL_SetModState(cast(SDL_Keymod)0);

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_          = history;
    t.splitEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                    "mesh.topoPen_split", "Topology Split",
                                                    MeshEditScope.Geometry);

    Mesh m;
    t.meshSrc_ = () => &m;
    m.addVertex(Vec3(-0.3f, 0, -0.3f));   // 0
    m.addVertex(Vec3( 0.3f, 0, -0.3f));   // 1
    m.addVertex(Vec3( 0.3f, 0,  0.3f));   // 2
    m.addVertex(Vec3(-0.3f, 0,  0.3f));   // 3
    // Wound [0,3,2,1] and not [0,1,2,3]: this rig's camera is the default
    // View's, which sits ABOVE the XZ plane, and [0,1,2,3] gives a -Y normal
    // — the quad would face AWAY from it. Split lands on a snap target, and a
    // back-facing candidate is not one at `backFace`'s measured default (task
    // 0538), so the wrong winding would turn the whole case into a no-op that
    // passes nothing. The undirected edge set, the vertex indices and the
    // 0→2 diagonal are all identical either way.
    m.addFace([0u, 3u, 2u, 1u]);
    m.buildLoops();

    Viewport vp = view.viewport();
    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);
    // Task 0523: this case's subject is the DISPATCH — that a plain-MMB
    // press/release really does reach `commitSplit` through the restructured
    // MIDDLE branch. Split lands on a snap target, and a snap target needs
    // snapping on, so the rig says so. Without this the release is a lawful
    // no-op and the case would pass vacuously while testing nothing.
    vts.put(penTestSnapOn());

    float sx0, sy0, sx2, sy2, ndcZ;
    assert(projectToWindowFull(m.vertices[0], vp, sx0, sy0, ndcZ),
        "setup: v0 must project on-screen for this rig");
    assert(projectToWindowFull(m.vertices[2], vp, sx2, sy2, ndcZ),
        "setup: v2 must project on-screen for this rig");

    // --- Guard-structure sanity: onMouseButtonDown's MIDDLE routing must
    // send a Ctrl/Shift chord to the Remove/Add Loop handlers, never to
    // Split's onPlainMmbDown. Each probe closes its OWN gesture with a
    // matching release before the next probe presses the SAME (middle)
    // button again — real hardware can never emit two DOWNs for one button
    // without an intervening UP, so leaving Add Loop's press unreleased
    // here would fabricate exactly the malformed same-button DOWN-DOWN
    // sequence `resetAllGestureArms`'s own doc comment says is NOT
    // (and need not be) guarded against; a real press/release cycle never
    // strands `addLoopArmed_` for the next press to inherit. ---
    SDL_SetModState(KMOD_CTRL);
    {
        SDL_MouseButtonEvent eCtrl;
        eCtrl.button = SDL_BUTTON_MIDDLE;
        eCtrl.x = cast(int)sx0;
        eCtrl.y = cast(int)sy0;
        t.onMouseButtonDown(eCtrl, vts);
        assert(!t.splitArmed_, "Ctrl+MMB must route to Remove, never arm Split");
        // Remove is a remove-on-DOWN gesture with no armed state of its own
        // (D2) — nothing to release.
    }
    SDL_SetModState(KMOD_SHIFT);
    {
        SDL_MouseButtonEvent eShiftDown;
        eShiftDown.button = SDL_BUTTON_MIDDLE;
        eShiftDown.x = cast(int)sx0;
        eShiftDown.y = cast(int)sy0;
        t.onMouseButtonDown(eShiftDown, vts);
        assert(!t.splitArmed_, "Shift+MMB must route to Add Loop, never arm Split");

        SDL_MouseButtonEvent eShiftUp;
        eShiftUp.button = SDL_BUTTON_MIDDLE;
        eShiftUp.x = cast(int)sx0;
        eShiftUp.y = cast(int)sy0;
        t.onMouseButtonUp(eShiftUp, vts);
        assert(!t.addLoopArmed_,
            "closing the probe's own press/release must disarm Add Loop, "
          ~ "leaving nothing stranded for the real Split press below");
    }

    // --- The real end-to-end drive: plain-MMB DOWN on v0, plain-MMB UP on
    // the diagonal v2 -- must arm at DOWN and commit the split at UP, through
    // the ACTUAL dispatch path (onMouseButtonDown -> onPlainMmbDown;
    // onMouseButtonUp -> the FIX-2-restructured MIDDLE branch -> commitSplit). ---
    SDL_SetModState(cast(SDL_Keymod)0);
    SDL_MouseButtonEvent eDown;
    eDown.button = SDL_BUTTON_MIDDLE;
    eDown.x = cast(int)sx0;
    eDown.y = cast(int)sy0;
    bool downConsumed = t.onMouseButtonDown(eDown, vts);
    assert(downConsumed, "plain-MMB press on a vertex must be consumed");
    assert(t.splitArmed_, "plain-MMB press on a vertex must arm Split");
    assert(t.splitSourceVert_ == 0, "must arm the pressed vertex (0) as the split source");

    SDL_MouseButtonEvent eUp;
    eUp.button = SDL_BUTTON_MIDDLE;
    eUp.x = cast(int)sx2;
    eUp.y = cast(int)sy2;
    bool upConsumed = t.onMouseButtonUp(eUp, vts);
    assert(upConsumed, "plain-MMB release on the diagonal vertex must be consumed");
    assert(!t.splitArmed_, "release must disarm Split regardless of outcome");

    assert(m.faces.length == 2, "the real dispatch path must have split the quad into 2 faces");
    assert(m.edges.length == 5, "the real dispatch path must have added the diagonal chord edge");
    assert(history.canUndo(), "the real dispatch path must record one undo entry");

    SDL_SetModState(cast(SDL_Keymod)0);   // leave the shared SDL modifier global clean
}

// ---------------------------------------------------------------------------
// uniqueRingVerts — REV1 FIX-1 (doc/topopen_p10_moveloop_plan.md): the
// moving-set on a small grid must be the classic IN-LINE edge-loop chain
// (`Mesh.selectLoopEdges`), NOT the perpendicular ring
// (`loopSliceRingEdges`/`collectEdgeRing`). Both cases below are HAND-
// COMPUTED against the grid's own known layout (`makeGridPlane(2)`: a 3x3
// vertex grid, `index(i,j) = i*3+j`), independently of any prior probe of
// `selectLoopEdges` itself:
//   * INTERIOR seed (edge 3-4, the middle row's own row-boundary edge)
//     walks the classic in-line chain STRAIGHT ACROSS the whole middle row
//     (i=1, j=0..2) — vertices {3,4,5} — dead-ending at the left/right
//     grid boundary on each side (an OPEN chain on a non-toroidal grid).
//   * BOUNDARY seed (edge 0-1, a genuine top-row perimeter edge) chains
//     along the grid's own closed perimeter (`selectLoopBorderChain`) —
//     every perimeter vertex EXCEPT the untouched center (4) — a CLOSED
//     loop.
// ---------------------------------------------------------------------------
unittest {
    import mesh : makeGridPlane;
    import std.format : format;

    Mesh m = makeGridPlane(2);   // 3x3 verts (0..8), 4 quads, 12 edges

    uint seedRow = m.edgeIndex(3, 4);
    assert(seedRow != uint.max, "setup: middle-row edge 3-4 must exist");
    auto rowVerts = TopologyPenTool.uniqueRingVerts(&m, seedRow);
    assert(rowVerts == [3u, 4u, 5u],
        format("interior seed must gather the in-line row chain {3,4,5}; got %s", rowVerts));

    uint seedBoundary = m.edgeIndex(0, 1);
    assert(seedBoundary != uint.max, "setup: top-row boundary edge 0-1 must exist");
    auto boundaryVerts = TopologyPenTool.uniqueRingVerts(&m, seedBoundary);
    assert(boundaryVerts == [0u, 1u, 2u, 3u, 5u, 6u, 7u, 8u],
        format("boundary seed must gather the full closed perimeter (every vertex but the "
             ~ "untouched center, 4); got %s", boundaryVerts));
}

// ---------------------------------------------------------------------------
// commitMoveLoop — T1 INTERIOR (doc/topopen_p10_moveloop_plan.md §Testing):
// a hand-built target set (each loop vertex offset by a fixed vector) must
// land EXACTLY at its target, topology (v/e/f counts) must stay unchanged
// (δ=0), the gesture is one atomic undo entry, and undo/redo restore the
// exact pre-/post-move positions.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import mesh : makeGridPlane;
    import std.format : format;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_             = history;
    t.moveLoopEditFactory_  = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                        "mesh.topoPen_moveloop", "Topology Move Loop",
                                                        MeshEditScope.Position);

    Mesh m = makeGridPlane(2);
    t.meshSrc_ = () => &m;

    uint seed = m.edgeIndex(3, 4);
    auto verts = TopologyPenTool.uniqueRingVerts(&m, seed);
    assert(verts == [3u, 4u, 5u]);

    Vec3[] orig;
    foreach (vi; verts) orig ~= m.vertices[vi];

    enum Vec3 offset = Vec3(0.2f, 1.5f, -0.4f);
    Vec3[] targets;
    foreach (o; orig) targets ~= o + offset;

    size_t vBefore = m.vertices.length, eBefore = m.edges.length, fBefore = m.faces.length;
    Viewport wvp;   // no camera in this unit rig: the 0555 landing needs one
    t.commitMoveLoop(verts, targets, wvp);

    foreach (i, vi; verts)
        assert((m.vertices[vi] - targets[i]).length < 1e-5f,
            format("loop vertex %d must land exactly at its target", vi));
    assert(m.vertices.length == vBefore && m.edges.length == eBefore && m.faces.length == fBefore,
        "Move Loop must never change topology (δ=0)");
    assert(history.canUndo(), "a real loop move must record one undo entry");

    history.undo();
    foreach (i, vi; verts)
        assert((m.vertices[vi] - orig[i]).length < 1e-5f,
            "undo must restore every loop vertex's exact pre-move position");

    history.redo();
    foreach (i, vi; verts)
        assert((m.vertices[vi] - targets[i]).length < 1e-5f,
            "redo must restore every loop vertex's exact moved position");
}

// ---------------------------------------------------------------------------
// commitMoveLoop — THE DESTRUCTIVE LANDING (task 0555).
//
// A loop grab brought onto other geometry with the application's snapping ON
// does not merely re-place its vertices: each one is ABSORBED into the vertex
// it landed on. THREE absorptions in ONE gesture, each into its own target,
// is what makes this the "per element, not per anchor" cell — a single query
// at a single cursor pixel answers with a single element and could not
// account for three.
//
// Rig: `makeGridPlane(2)`, seen from the side its quads face
// (`makeGridPlaneFrontViewport` — at the +Y camera every candidate is
// back-facing and `backFace`'s measured default would refuse them all, so the
// no-op would arrive for the wrong reason). The middle COLUMN {1,4,7} is
// dragged onto the right column and stopped `kShort` short of it — ~4px at
// this camera's 80px-per-unit, comfortably inside the 24px acceptance.
//
// STOPPED SHORT ON PURPOSE, and it is not timidity about the radius: a moved
// vertex placed EXACTLY on its target leaves every face it belongs to
// zero-area, `Mesh.faceNormal` answers a degenerate face with its `(0,1,0)`
// FALLBACK, and the pen's orientation admission then reads that fallback as
// back-facing and refuses the target. A real drag lands near, not on, so a
// rig that lands on would be testing the fallback rather than the weld.
//
// Deltas, derived by hand from the rewrite rather than read back: 1→2, 4→5,
// 7→8 leaves faces [0,2,5,3] and [3,5,8,6] standing and collapses the two
// cells the column was dragged across, i.e. V 9→6, E 12→7, F 4→2.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import mesh : makeGridPlane;
    import std.format : format;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_             = history;
    t.moveLoopEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                       "mesh.topoPen_moveloop", "Topology Move Loop",
                                                       MeshEditScope.Position);

    Mesh m = makeGridPlane(2);
    t.meshSrc_ = () => &m;
    assert(m.vertices.length == 9 && m.edges.length == 12 && m.faces.length == 4,
        "setup: makeGridPlane(2) must be V=9 E=12 F=4");

    // ~4px short of the right column at this camera — see the header.
    enum Vec3 kShort = Vec3(-0.05f, 0, 0);
    uint[] verts   = [1u, 4u, 7u];
    Vec3[] targets = [m.vertices[2] + kShort,
                      m.vertices[5] + kShort,
                      m.vertices[8] + kShort];

    auto vp = makeGridPlaneFrontViewport();
    // The gate, said out loud: the landing is destructive only because the
    // application's shared snap enable is on for this gesture.
    t.dragSnap_ = *penTestSnapOn();

    t.commitMoveLoop(verts, targets, vp);

    assert(m.vertices.length == 6,
        format("all THREE loop vertices must be absorbed, each into its own target "
             ~ "(V 9 -> 6); got V=%d", m.vertices.length));
    assert(m.edges.length == 7,
        format("the absorbed column takes five edges with it (E 12 -> 7); got E=%d",
               m.edges.length));
    assert(m.faces.length == 2,
        format("the two cells the column was dragged across collapse (F 4 -> 2); got F=%d",
               m.faces.length));

    // The survivors are the TARGETS, at their own untouched positions — the
    // grab is absorbed into the target, not averaged with it.
    foreach (want; [Vec3(1, 0, -1), Vec3(1, 0, 0), Vec3(1, 0, 1)]) {
        bool found = false;
        foreach (v; m.vertices) if ((v - want).length < 1e-5f) found = true;
        assert(found, format("weld target %s must survive at its own position", want));
    }

    // ONE undo step for the whole gesture, and it puts the topology back.
    assert(history.canUndo(), "a welding loop move must record one undo entry");
    history.undo();
    assert(m.vertices.length == 9 && m.edges.length == 12 && m.faces.length == 4,
        format("one undo must restore the whole gesture — move AND weld; got V=%d E=%d F=%d",
               m.vertices.length, m.edges.length, m.faces.length));
    assert(!history.canUndo(),
        "the gesture must be ONE entry: after a single undo there is nothing left to undo");

    history.redo();
    assert(m.vertices.length == 6 && m.faces.length == 2,
        "redo must re-apply the whole gesture, weld included");
}

// ---------------------------------------------------------------------------
// commitMoveLoop — the same drag with the application's snapping OFF is
// NON-destructive (task 0555). The gate is the shared snap enable, and this
// is the arm that proves the case above is testing it rather than testing
// "vertices that land on each other always merge".
//
// Deliberately identical to the case above in every other respect, down to
// the targets: only `dragSnap_` differs.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import mesh : makeGridPlane;
    import std.format : format;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_             = history;
    t.moveLoopEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                       "mesh.topoPen_moveloop", "Topology Move Loop",
                                                       MeshEditScope.Position);

    Mesh m = makeGridPlane(2);
    t.meshSrc_ = () => &m;

    enum Vec3 kShort = Vec3(-0.05f, 0, 0);   // the welding arm's own offset
    uint[] verts   = [1u, 4u, 7u];
    Vec3[] targets = [m.vertices[2] + kShort,
                      m.vertices[5] + kShort,
                      m.vertices[8] + kShort];
    auto vp = makeGridPlaneFrontViewport();
    // NO `dragSnap_` — `SnapPacket.init.enabled` is false, which is the
    // application's own shipped default.
    assert(!t.dragSnap_.enabled, "setup: this arm runs with snapping OFF");

    t.commitMoveLoop(verts, targets, vp);

    assert(m.vertices.length == 9 && m.edges.length == 12 && m.faces.length == 4,
        format("with snapping off the loop move must stay position-only (V=9 E=12 F=4); "
             ~ "got V=%d E=%d F=%d", m.vertices.length, m.edges.length, m.faces.length));
    foreach (i, vi; verts)
        assert((m.vertices[vi] - targets[i]).length < 1e-5f,
            format("loop vertex %d must still land exactly where the move put it — well "
                 ~ "inside another vertex's acceptance radius, and NOT merged into it", vi));
}

// ---------------------------------------------------------------------------
// THE DESTRUCTIVE LANDING on the ELEMENT grab (task 0555) — the OTHER commit
// path, `finishMove`, driven end to end through the real SDL dispatch: a plain
// LMB press on a vertex arms Move, and the release absorbs the grab into the
// vertex it came to rest on.
//
// It is a separate case from the loop one above and not a duplicate of it:
// `finishMove` has its own undo bookkeeping (a lazily captured baseline and a
// net-no-op test that compares the moving set against its arm-time base — a
// test that CANNOT judge a weld, because the vertex array was compacted under
// the indices it holds), and this is what pins that.
//
// `activeMeshResolver` is pointed at a DIFFERENT mesh for the duration: this
// rig has no GL, and `applyMoveTargets` refreshes the display unconditionally
// once the resolver is unset. Saying "the mesh under test is not the mesh on
// screen" is the resolver's own contract, and it makes the refresh the no-op a
// headless rig needs. Restored on the way out — it is a `__gshared` global.
// ---------------------------------------------------------------------------
version (unittest) private void driveWeldingVertexGrab(TopologyPenTool t, ref Mesh m,
                                                       const ref Viewport vp,
                                                       ref VectorStack vts,
                                                       uint grab, Vec3 landing) {
    import std.format : format;
    ImVec2 pg;
    assert(TopologyPenTool.projectWorldPt(m.vertices[grab], vp, pg),
        "setup: the grabbed vertex must project");

    SDL_MouseButtonEvent down;
    down.button = SDL_BUTTON_LEFT;
    down.x = cast(int)pg.x; down.y = cast(int)pg.y;
    assert(t.onMouseButtonDown(down, vts),
        "a plain-LMB press on a vertex must be consumed in Move mode");
    assert(t.moveArmed_ && t.moveElem_ == MoveElem.Vertex,
        format("the press must arm a VERTEX grab; armed=%s elem=%s",
               t.moveArmed_, t.moveElem_));
    assert(t.moveVerts_ == [grab], "the press must arm the pressed vertex");

    // The release's landing is whatever the constraint stage says the cursor
    // hit — the Vertex law rides that hit, not the pixel — so the rig states
    // it directly.
    auto hit = new ConstrainHitPacket;
    hit.hit   = true;
    hit.point = landing;
    vts.put(hit);

    ImVec2 pl;
    assert(TopologyPenTool.projectWorldPt(landing, vp, pl), "setup: the landing must project");
    SDL_MouseButtonEvent up;
    up.button = SDL_BUTTON_LEFT;
    up.x = cast(int)pl.x; up.y = cast(int)pl.y;
    assert(t.onMouseButtonUp(up, vts), "the release of an armed Move must be consumed");
    assert(!t.moveArmed_, "the release must disarm whatever the outcome");
}

unittest {
    import view : View;
    import editmode : EditMode;
    import mesh : makeGridPlane;
    import display_sync : activeMeshResolver;
    import toolpipe.packets : SubjectPacket;
    import std.format : format;

    Mesh offscreen;
    auto savedResolver = activeMeshResolver;
    activeMeshResolver = () => &offscreen;
    scope(exit) activeMeshResolver = savedResolver;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_         = history;
    t.moveEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                  "mesh.topoPen_move", "Topology Move",
                                                  MeshEditScope.Position);
    Mesh m = makeGridPlane(2);
    t.meshSrc_ = () => &m;

    auto vp = makeGridPlaneFrontViewport();
    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);
    vts.put(penTestSnapOn());

    // Grab v1 and land it just short of v2 — the same "near, not on" reasoning
    // the loop case documents.
    driveWeldingVertexGrab(t, m, vp, vts, 1u, m.vertices[2] + Vec3(-0.05f, 0, 0));

    assert(m.vertices.length == 8,
        format("the grabbed vertex must be absorbed by the vertex it landed on (V 9 -> 8); "
             ~ "got V=%d", m.vertices.length));
    assert(m.edges.length == 11,
        format("the edge between grab and target goes with it (E 12 -> 11); got E=%d",
               m.edges.length));
    assert(m.faces.length == 4,
        format("no face is lost — the shared quad becomes a triangle (F 4); got F=%d",
               m.faces.length));
    size_t tris = 0;
    foreach (ref f; m.faces) if (f.length == 3) ++tris;
    assert(tris == 1,
        format("exactly the one quad that held BOTH the grab and its target collapses to a "
             ~ "triangle; got %d triangles", tris));
    bool atTarget = false, atLanding = false;
    foreach (v; m.vertices) {
        if ((v - Vec3(1.00f, 0, -1)).length < 1e-5f) atTarget  = true;
        if ((v - Vec3(0.95f, 0, -1)).length < 1e-5f) atLanding = true;
    }
    assert(atTarget && !atLanding,
        "the survivor sits at the TARGET's own position, not where the drag stopped — the "
      ~ "grab is absorbed INTO the target, not averaged with it");

    // ONE undo entry for press-drag-release-absorb, and it restores everything.
    assert(history.canUndo(), "a welding move must record one undo entry");
    history.undo();
    assert(m.vertices.length == 9 && m.edges.length == 12 && m.faces.length == 4,
        format("one undo must restore the whole gesture — move AND weld; got V=%d E=%d F=%d",
               m.vertices.length, m.edges.length, m.faces.length));
    assert(!history.canUndo(),
        "the gesture must be ONE entry: after a single undo there is nothing left to undo");
}

// The same press and the same landing with the application's snapping OFF: the
// vertex moves and nothing is destroyed. The gate, on the element path.
unittest {
    import view : View;
    import editmode : EditMode;
    import mesh : makeGridPlane;
    import display_sync : activeMeshResolver;
    import toolpipe.packets : SubjectPacket;
    import std.format : format;

    Mesh offscreen;
    auto savedResolver = activeMeshResolver;
    activeMeshResolver = () => &offscreen;
    scope(exit) activeMeshResolver = savedResolver;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_         = history;
    t.moveEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                  "mesh.topoPen_move", "Topology Move",
                                                  MeshEditScope.Position);
    Mesh m = makeGridPlane(2);
    t.meshSrc_ = () => &m;

    auto vp = makeGridPlaneFrontViewport();
    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);
    // No SnapPacket at all — the application's shipped default is snapping off.

    immutable Vec3 landing = m.vertices[2] + Vec3(-0.05f, 0, 0);
    driveWeldingVertexGrab(t, m, vp, vts, 1u, landing);

    assert(m.vertices.length == 9 && m.edges.length == 12 && m.faces.length == 4,
        format("with snapping off the grab must only MOVE (V=9 E=12 F=4); got V=%d E=%d F=%d",
               m.vertices.length, m.edges.length, m.faces.length));
    assert((m.vertices[1] - landing).length < 1e-5f,
        "the grabbed vertex must sit exactly where the drag put it, unmerged");
}

// ---------------------------------------------------------------------------
// THE ACCEPTANCE RADIUS is the gate, not "is there a nearest vertex at all"
// (task 0555).
//
// The reference parks the nearest element in its target slot BEFORE applying
// the radius and folds the radius into the query's RETURN — so "a target
// exists" is true far more often than "the query answered", and a port that
// gates on the former welds well outside the radius. Ours gates on the answer
// (`findSourceVertex` returns -1 outside `topoPenSnapAcceptPx`), and this is
// the case that says so out loud.
//
// Same rig and same grab as the welding element case below; only the landing
// distance changes. 0.375 world units is 30px at this camera's 80px-per-unit,
// outside the 24px acceptance — and the case asserts that v2 IS the nearest
// admissible vertex, so what stops the weld is demonstrably the radius and not
// an empty query.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import mesh : makeGridPlane;
    import display_sync : activeMeshResolver;
    import toolpipe.packets : SubjectPacket;
    import std.format : format;

    Mesh offscreen;
    auto savedResolver = activeMeshResolver;
    activeMeshResolver = () => &offscreen;
    scope(exit) activeMeshResolver = savedResolver;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_         = history;
    t.moveEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                  "mesh.topoPen_move", "Topology Move",
                                                  MeshEditScope.Position);
    Mesh m = makeGridPlane(2);
    t.meshSrc_ = () => &m;

    auto vp = makeGridPlaneFrontViewport();
    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);
    vts.put(penTestSnapOn());

    immutable Vec3 landing = m.vertices[2] + Vec3(-0.375f, 0, 0);

    // The precondition, computed here rather than asked of the code under
    // test: vertex 2 is the NEAREST other vertex to that landing, and it sits
    // outside the acceptance. Without the first half the case could pass
    // because the query found nothing at all — a different reason from the one
    // it names.
    ImVec2 pl;
    assert(TopologyPenTool.projectWorldPt(landing, vp, pl), "setup: the landing must project");
    float best = float.infinity;
    size_t bestVi = size_t.max;
    foreach (vi; 0 .. m.vertices.length) {
        if (vi == 1) continue;                    // the grab itself, always excluded
        ImVec2 pc;
        if (!TopologyPenTool.projectWorldPt(m.vertices[vi], vp, pc)) continue;
        immutable float d = hypot(pc.x - pl.x, pc.y - pl.y);
        if (d < best) { best = d; bestVi = vi; }
    }
    assert(bestVi == 2,
        format("setup: vertex 2 must be the nearest candidate to the landing; got %d", bestVi));
    assert(best > topoPenSnapAcceptPx(vp, *penTestSnapOn()),
        format("setup: and it must sit OUTSIDE the %.0fpx acceptance, or the radius is not "
             ~ "what refuses it; distance %.1fpx",
               topoPenSnapAcceptPx(vp, *penTestSnapOn()), best));

    driveWeldingVertexGrab(t, m, vp, vts, 1u, landing);

    assert(m.vertices.length == 9 && m.edges.length == 12 && m.faces.length == 4,
        format("a landing OUTSIDE the acceptance radius must only move (V=9 E=12 F=4); "
             ~ "got V=%d E=%d F=%d", m.vertices.length, m.edges.length, m.faces.length));
    assert((m.vertices[1] - landing).length < 1e-5f,
        "the grabbed vertex must sit exactly where the drag put it, unabsorbed");
}

// ---------------------------------------------------------------------------
// THE EDGE GRAB — the measured headline cell (task 0555/0545): dV -2, dE -3,
// dF -1, because BOTH endpoints are absorbed, each into its own target.
//
// The full gesture, through the real dispatch: press on the middle column's
// edge, drag it right, release just short of the right column. Unlike the
// vertex grab, an edge grab's law re-snaps every moved vertex to the
// BACKGROUND, so this rig installs one — a big quad in the same y=0 plane the
// grid lives in, and the camera looks straight down onto that plane, so the
// screen-shifted point is already on the background and the nearest foot is
// the identity. That keeps the arithmetic exact and leaves the ABSORPTION as
// the only thing under test.
//
// The deltas are derived by hand from the rewrite: 1→2 and 4→5 leave [0,2,5,3]
// and [3,5,7,6] standing as quads, [5,8,7] as a triangle, and collapse the
// cell the edge was dragged across.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import mesh : makeGridPlane;
    import display_sync : activeMeshResolver;
    import snap : setBackgroundSnapSources;
    import toolpipe.packets : SubjectPacket;
    import std.format : format;

    Mesh offscreen;
    auto savedResolver = activeMeshResolver;
    activeMeshResolver = () => &offscreen;
    scope(exit) activeMeshResolver = savedResolver;

    // The background the moved vertices re-snap onto: coplanar with the grid,
    // so the re-snap is the identity and the drag's screen delta maps to an
    // exact in-plane world delta.
    Mesh bg;
    bg.addVertex(Vec3(-3, 0, -3)); bg.addVertex(Vec3(3, 0, -3));
    bg.addVertex(Vec3( 3, 0,  3)); bg.addVertex(Vec3(-3, 0, 3));
    bg.addFace([0u, 1u, 2u, 3u]);
    bg.rebuildEdges();
    bg.buildLoops();
    const(Mesh)*[] sources = [cast(const(Mesh)*)&bg];
    import math : ModelSpace;
    setBackgroundSnapSources(sources, new ModelSpace[](sources.length));
    scope(exit) setBackgroundSnapSources(null, null);

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_         = history;
    t.moveEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                  "mesh.topoPen_move", "Topology Move",
                                                  MeshEditScope.Position);
    Mesh m = makeGridPlane(2);
    t.meshSrc_ = () => &m;

    auto vp = makeGridPlaneFrontViewport();
    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);
    vts.put(penTestSnapOn());

    // The press: the screen midpoint of edge 1-4, which is 40px from either
    // endpoint and so resolves as an EDGE grab and not a vertex one.
    ImVec2 p1, p4;
    assert(TopologyPenTool.projectWorldPt(m.vertices[1], vp, p1));
    assert(TopologyPenTool.projectWorldPt(m.vertices[4], vp, p4));
    immutable int pressX = cast(int)((p1.x + p4.x) * 0.5f);
    immutable int pressY = cast(int)((p1.y + p4.y) * 0.5f);

    // The drag, stated in WORLD terms and converted: stop 0.05 short of the
    // right column, the same "near, not on" reasoning the other cases use.
    ImVec2 pLand;
    assert(TopologyPenTool.projectWorldPt(m.vertices[1] + Vec3(0.95f, 0, 0), vp, pLand));
    immutable int dx = cast(int)(pLand.x - p1.x), dy = cast(int)(pLand.y - p1.y);
    assert(dx * dx + dy * dy > 9,
        "setup: the drag must clear the tool's own 3px click-vs-drag gate");

    SDL_MouseButtonEvent down;
    down.button = SDL_BUTTON_LEFT;
    down.x = pressX; down.y = pressY;
    assert(t.onMouseButtonDown(down, vts), "a plain-LMB press on an edge must be consumed");
    assert(t.moveArmed_ && t.moveElem_ == MoveElem.Edge,
        format("the press must arm an EDGE grab; armed=%s elem=%s", t.moveArmed_, t.moveElem_));

    SDL_MouseMotionEvent motion;
    motion.x = pressX + dx / 2; motion.y = pressY + dy / 2;
    t.onMouseMotion(motion, vts);

    SDL_MouseButtonEvent up;
    up.button = SDL_BUTTON_LEFT;
    up.x = pressX + dx; up.y = pressY + dy;
    assert(t.onMouseButtonUp(up, vts), "the release of an armed edge Move must be consumed");

    assert(m.vertices.length == 7,
        format("BOTH endpoints must be absorbed, each into its own target (V 9 -> 7); got V=%d",
               m.vertices.length));
    assert(m.edges.length == 9,
        format("dE -3, the measured cell; got E=%d", m.edges.length));
    assert(m.faces.length == 3,
        format("dF -1 — the cell the edge was dragged across collapses; got F=%d",
               m.faces.length));
    foreach (want; [Vec3(1, 0, -1), Vec3(1, 0, 0)]) {
        bool found = false;
        foreach (v; m.vertices) if ((v - want).length < 1e-4f) found = true;
        assert(found, format("weld target %s must survive at its own position", want));
    }
    foreach (v; m.vertices)
        assert((v - Vec3(0.95f, 0, -1)).length > 1e-3f
            && (v - Vec3(0.95f, 0,  0)).length > 1e-3f,
            "no vertex may be left where the drag stopped — both were absorbed");

    // ONE undo entry for the whole gesture, weld included.
    assert(history.canUndo(), "a welding edge move must record one undo entry");
    history.undo();
    assert(m.vertices.length == 9 && m.edges.length == 12 && m.faces.length == 4,
        format("one undo must restore the whole gesture; got V=%d E=%d F=%d",
               m.vertices.length, m.edges.length, m.faces.length));
    assert(!history.canUndo(),
        "the gesture must be ONE entry: after a single undo there is nothing left to undo");
}

// ---------------------------------------------------------------------------
// A weld must never be dropped by the net-no-op test (task 0555).
//
// `recordLiveMove` skips the undo entry for a drag that wandered and came home
// — it compares the moving set against its arm-time base. After a weld that
// comparison is not merely wrong, it is MEANINGLESS: the vertex array was
// compacted under the very indices it holds, so it reads whatever geometry
// slid into those slots. This rig makes it read an ANSWER rather than garbage,
// and the answer is the wrong one.
//
// Two coincident-but-separate vertices at the origin, one per quad (a legal
// unwelded seam). The grab is vertex 0; absorbing it compacts vertex 1 down
// into slot 0, at the identical position — so the net test compares the
// arm-time base against a vertex that merely happens to sit where the grab
// started, concludes "nothing happened", and throws away the only undo entry
// the destroyed topology has. The gesture would be UNDOABLE-PROOF: a hard
// failure of the one non-negotiable, one Ctrl+Z per gesture.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import display_sync : activeMeshResolver;
    import toolpipe.packets : SubjectPacket;
    import std.format : format;

    Mesh offscreen;
    auto savedResolver = activeMeshResolver;
    activeMeshResolver = () => &offscreen;
    scope(exit) activeMeshResolver = savedResolver;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_         = history;
    t.moveEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                  "mesh.topoPen_move", "Topology Move",
                                                  MeshEditScope.Position);

    // Two quads in the XZ plane, wound like `makeGridPlane`'s cells so both
    // face -Y (the side `makeGridPlaneFrontViewport` looks from).
    Mesh m;
    m.addVertex(Vec3( 0.00f, 0,  0.00f));   // 0 — quad A's corner, THE GRAB
    m.addVertex(Vec3( 0.00f, 0,  0.00f));   // 1 — quad B's corner, coincident with 0
    m.addVertex(Vec3( 0.25f, 0,  0.00f));   // 2 — the weld target
    m.addVertex(Vec3( 0.25f, 0,  0.25f));   // 3
    m.addVertex(Vec3( 0.00f, 0,  0.25f));   // 4
    m.addVertex(Vec3(-0.25f, 0, -0.25f));   // 5
    m.addVertex(Vec3( 0.00f, 0, -0.25f));   // 6
    m.addVertex(Vec3(-0.25f, 0,  0.00f));   // 7
    m.addFace([0u, 2u, 3u, 4u]);
    m.addFace([5u, 6u, 1u, 7u]);
    m.rebuildEdges();
    m.buildLoops();
    t.meshSrc_ = () => &m;

    auto vp = makeGridPlaneFrontViewport();
    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);
    vts.put(penTestSnapOn());

    // Land just short of vertex 2 — ~2px at this camera, inside the acceptance.
    driveWeldingVertexGrab(t, m, vp, vts, 0u, Vec3(0.22f, 0, 0));

    assert(m.vertices.length == 7,
        format("the grab must be absorbed by vertex 2 (V 8 -> 7); got V=%d", m.vertices.length));
    assert((m.vertices[0] - Vec3(0, 0, 0)).length < 1e-6f,
        "setup: the compaction must slide the coincident twin into slot 0, or this case is "
      ~ "not the one it names");

    // THE CLAIM: the entry exists. Without the weld flag the net test above
    // would have compared slot 0 against the grab's arm-time position, found
    // them equal, and dropped it.
    assert(history.canUndo(),
        "a gesture that DESTROYED topology must record an undo entry, whatever the moving "
      ~ "set's stale indices now happen to hold");
    history.undo();
    assert(m.vertices.length == 8 && m.faces.length == 2,
        format("one undo must restore the absorbed vertex; got V=%d F=%d",
               m.vertices.length, m.faces.length));
    foreach (ref f; m.faces)
        assert(f.length == 4, "undo must restore both quads");
}

// A press that never moved anything cannot have been "brought to within"
// anything, so it must not absorb — even when the grab is already sitting
// inside another vertex's acceptance radius, which on a dense enough mesh it
// always is (task 0555).
//
// OURS, by reasoning rather than by measurement: the reference welds from its
// per-drag-event evaluate, and a click that produces no drag event produces no
// weld. Without this gate the tool would eat a vertex for being CLICKED, which
// is not a behaviour anything measured shows.
//
// Rig: `makeGridPlane(8)` — 0.25 world units per cell, i.e. 20px at this
// camera, so every vertex has neighbours INSIDE the 24px acceptance and the
// gate is the only thing standing between a click and a weld.
unittest {
    import view : View;
    import editmode : EditMode;
    import mesh : makeGridPlane;
    import display_sync : activeMeshResolver;
    import toolpipe.packets : SubjectPacket;
    import std.format : format;

    Mesh offscreen;
    auto savedResolver = activeMeshResolver;
    activeMeshResolver = () => &offscreen;
    scope(exit) activeMeshResolver = savedResolver;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_         = history;
    t.moveEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                  "mesh.topoPen_move", "Topology Move",
                                                  MeshEditScope.Position);
    Mesh m = makeGridPlane(8);
    t.meshSrc_ = () => &m;

    auto vp = makeGridPlaneFrontViewport();
    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);
    vts.put(penTestSnapOn());

    immutable size_t vBefore = m.vertices.length;
    immutable size_t fBefore = m.faces.length;

    // The precondition this case rests on: vertex 0's nearest neighbour is
    // inside the acceptance radius, so a weld is available to be wrongly taken.
    t.dragSnap_ = *penTestSnapOn();
    ImVec2 p0;
    assert(TopologyPenTool.projectWorldPt(m.vertices[0], vp, p0), "setup: v0 must project");
    assert(t.resolveSnapTargetVert(cast(int)p0.x, cast(int)p0.y, vp, [0u]) >= 0,
        "setup: v0 must have an admissible neighbour inside the acceptance radius, or this "
      ~ "case cannot tell a gate from an empty query");
    t.dragSnap_ = SnapPacket.init;

    // Press and release on that vertex, at the same pixel, with no surface hit
    // — the plain stationary click.
    SDL_MouseButtonEvent down;
    down.button = SDL_BUTTON_LEFT;
    down.x = cast(int)p0.x; down.y = cast(int)p0.y;
    assert(t.onMouseButtonDown(down, vts), "a press on a vertex must be consumed");
    assert(t.moveArmed_, "the press must arm Move");
    SDL_MouseButtonEvent up;
    up.button = SDL_BUTTON_LEFT;
    up.x = cast(int)p0.x; up.y = cast(int)p0.y;
    assert(t.onMouseButtonUp(up, vts), "the release must be consumed");

    assert(m.vertices.length == vBefore && m.faces.length == fBefore,
        format("a stationary click must not absorb anything — V %d -> %d, F %d -> %d",
               vBefore, m.vertices.length, fBefore, m.faces.length));
    assert(!history.canUndo(),
        "and it must record no undo entry at all: it is not an edit");
}

// ---------------------------------------------------------------------------
// commitMoveLoop — T2 BOUNDARY (doc/topopen_p10_moveloop_plan.md §Testing):
// the same commit contract over the full closed-perimeter moving-set (8
// vertices) — every entry lands at its target, δ=0.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import mesh : makeGridPlane;
    import std.format : format;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_            = history;
    t.moveLoopEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                       "mesh.topoPen_moveloop", "Topology Move Loop",
                                                       MeshEditScope.Position);

    Mesh m = makeGridPlane(2);
    t.meshSrc_ = () => &m;

    uint seed = m.edgeIndex(0, 1);
    auto verts = TopologyPenTool.uniqueRingVerts(&m, seed);
    assert(verts == [0u, 1u, 2u, 3u, 5u, 6u, 7u, 8u]);

    Vec3[] targets;
    foreach (vi; verts) targets ~= m.vertices[vi] + Vec3(0, 0.75f, 0);

    size_t vBefore = m.vertices.length, eBefore = m.edges.length, fBefore = m.faces.length;
    Viewport wvp;   // no camera in this unit rig: the 0555 landing needs one
    t.commitMoveLoop(verts, targets, wvp);

    foreach (i, vi; verts)
        assert((m.vertices[vi] - targets[i]).length < 1e-5f,
            format("perimeter vertex %d must land exactly at its target", vi));
    // The untouched center (4) must be left exactly alone.
    assert((m.vertices[4] - Vec3(0, 0, 0)).length < 1e-6f,
        "the center vertex (outside the boundary loop) must not move");
    assert(m.vertices.length == vBefore && m.edges.length == eBefore && m.faces.length == fBefore,
        "Move Loop must never change topology (δ=0)");
    assert(history.canUndo(), "a real perimeter loop move must record one undo entry");
}

// ---------------------------------------------------------------------------
// commitMoveLoop — T3 NO-OP GUARD (doc/topopen_p10_moveloop_plan.md
// §Undo): targets identical (within eps) to the current positions must be a
// byte-identical no-op — no mutation, no undo entry.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import mesh : makeGridPlane;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_            = history;
    t.moveLoopEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                       "mesh.topoPen_moveloop", "Topology Move Loop",
                                                       MeshEditScope.Position);

    Mesh m = makeGridPlane(2);
    t.meshSrc_ = () => &m;

    uint seed = m.edgeIndex(3, 4);
    auto verts = TopologyPenTool.uniqueRingVerts(&m, seed);

    Vec3[] targets;
    foreach (vi; verts) targets ~= m.vertices[vi];   // exactly the current positions

    auto before = MeshSnapshot.capture(m);
    Viewport wvp;   // no camera in this unit rig: the 0555 landing needs one
    t.commitMoveLoop(verts, targets, wvp);
    auto after = MeshSnapshot.capture(m);

    assert(after.vertices == before.vertices, "an all-stationary target set must not move any vertex");
    assert(!history.canUndo(), "an all-stationary commit must record NO undo entry");
}

// ---------------------------------------------------------------------------
// commitMoveLoop — T4 PARTIAL-MISS (REV1 FIX-2, doc/topopen_p10_moveloop_plan.md
// "The pinned drag-mapping" / REV1): simulates a per-vertex background-ray
// MISS by feeding `commitMoveLoop` a `targets[]` where SOME entries equal
// `orig[i]` exactly (the "keep original" policy `perVertexTargets` applies
// on a miss) while others carry a real offset. The specific held vertex
// must stay EXACTLY put while the others move — locking the "miss -> keep
// original per-vertex" contract at the commit layer (there is no
// Escape-cancel in this tool family, so a partial-miss commits atomically,
// as one single undo entry covering the whole gesture).
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import mesh : makeGridPlane;
    import std.format : format;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_            = history;
    t.moveLoopEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                       "mesh.topoPen_moveloop", "Topology Move Loop",
                                                       MeshEditScope.Position);

    Mesh m = makeGridPlane(2);
    t.meshSrc_ = () => &m;

    uint seed = m.edgeIndex(3, 4);
    auto verts = TopologyPenTool.uniqueRingVerts(&m, seed);   // [3, 4, 5]
    assert(verts == [3u, 4u, 5u]);

    Vec3[] orig;
    foreach (vi; verts) orig ~= m.vertices[vi];

    // verts[0]=3 and verts[2]=5 get a real offset ("hit"); verts[1]=4's
    // target is set to its OWN original position, simulating a per-vertex
    // ray MISS for the middle loop vertex.
    Vec3[] targets = [orig[0] + Vec3(0, 1.0f, 0), orig[1], orig[2] + Vec3(0, 1.0f, 0)];

    Viewport wvp;   // no camera in this unit rig: the 0555 landing needs one
    t.commitMoveLoop(verts, targets, wvp);

    assert((m.vertices[3] - targets[0]).length < 1e-5f, "the HIT vertex (3) must move to its target");
    assert((m.vertices[4] - orig[1]).length < 1e-6f,
        format("the MISS vertex (4) must stay EXACTLY at its original position; got %s", m.vertices[4]));
    assert((m.vertices[5] - targets[2]).length < 1e-5f, "the HIT vertex (5) must move to its target");
    assert(history.canUndo(),
        "a partial-miss gesture (some verts moved) must still record ONE atomic undo entry");

    history.undo();
    foreach (i, vi; verts)
        assert((m.vertices[vi] - orig[i]).length < 1e-5f,
            "undo must restore every loop vertex — including the ones that never moved — exactly");
}

// ---------------------------------------------------------------------------
// commitMoveLoop — T5 SPACING PRESERVED / ON-SURFACE (doc/topopen_p10_moveloop_plan.md
// §Testing "spacing / no-collapse"): targets computed from an INJECTED
// analytic curved surface (a parabola `y = 0.3*x^2` over the loop's own
// x-line, evaluated HERE in-test — no Document background needed) must
// each lie exactly ON that surface (re-derived independently, never by
// re-reading the target array's own construction) and consecutive
// loop-vertex distances must stay within a band of the PRE-drag spacing —
// proving the commit does not collapse the loop toward a point, unlike a
// hypothetical implementation that averaged/interpolated instead of writing
// every target verbatim.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import mesh : makeGridPlane;
    import std.math   : abs;
    import std.format : format;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_            = history;
    t.moveLoopEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                       "mesh.topoPen_moveloop", "Topology Move Loop",
                                                       MeshEditScope.Position);

    Mesh m = makeGridPlane(2);
    t.meshSrc_ = () => &m;

    uint seed = m.edgeIndex(3, 4);
    auto verts = TopologyPenTool.uniqueRingVerts(&m, seed);   // [3, 4, 5] at x=-1,0,1 (z=0)

    static float heightAt(float x) { return 0.3f * x * x; }

    Vec3[] orig;
    foreach (vi; verts) orig ~= m.vertices[vi];
    Vec3[] targets;
    foreach (o; orig) targets ~= Vec3(o.x, heightAt(o.x), o.z);

    // Pre-drag consecutive spacing (all exactly 1.0 on the flat grid).
    float preD01 = (orig[1] - orig[0]).length;
    float preD12 = (orig[2] - orig[1]).length;

    Viewport wvp;   // no camera in this unit rig: the 0555 landing needs one
    t.commitMoveLoop(verts, targets, wvp);

    // On-surface: re-derive the expected height independently per vertex
    // (never reusing the `targets` array's own values).
    foreach (i, vi; verts) {
        float expectedY = heightAt(m.vertices[vi].x);
        assert(abs(m.vertices[vi].y - expectedY) < 1e-5f,
            format("loop vertex %d must lie exactly on the injected surface y=0.3x^2; "
                 ~ "got y=%f expected %f", vi, m.vertices[vi].y, expectedY));
    }

    float postD01 = (m.vertices[verts[1]] - m.vertices[verts[0]]).length;
    float postD12 = (m.vertices[verts[2]] - m.vertices[verts[1]]).length;
    assert(postD01 > preD01 * 0.5f && postD01 < preD01 * 2.0f,
        format("consecutive spacing (0-1) must stay within a band of pre-drag; pre=%f post=%f",
               preD01, postD01));
    assert(postD12 > preD12 * 0.5f && postD12 < preD12 * 2.0f,
        format("consecutive spacing (1-2) must stay within a band of pre-drag; pre=%f post=%f",
               preD12, postD12));
}

// ---------------------------------------------------------------------------
// resnapToBackground — TASK 0503, THE MEASURED LAW ON A TILTED BACKGROUND.
//
// This is the fixture the law needs. On a background PARALLEL to the plane
// the drag resolves on, the per-vertex correction is the IDENTITY, which is
// why four earlier captures (every one of them on a parallel background)
// could not see the difference between the camera ray this tool used to cast
// and the nearest foot the reference actually takes. The rig here is cell A's
// own construction: the source edge runs SCREEN-HORIZONTALLY, the background
// is tilted about the SCREEN-VERTICAL axis, so the two source vertices sit at
// different depths on it.
//
// Three scored invariants, all computed here from scratch, never by a second
// call into the code under test:
//
//   (a) each target lies ON the background plane (the capture's own
//       `d(new, bg)` channel: 6.8e-10 … 8.4e-9);
//   (b) |new edge| / |source edge| == cos(tilt) at 30/45/60 degrees — the
//       capture measured 0.866025692 / 0.707106741 / 0.500000075 against
//       cos to 2.9e-7. A per-vertex CAMERA RAY predicts 1.804 / 2.484 /
//       4.369 on the same three cells, and every rigid law predicts 1.000,
//       so this single number refutes both by 0.94-3.87 and 0.13-0.50;
//   (c) each target equals the independently-derived PERPENDICULAR FOOT of
//       its own source vertex — which refutes anchor-plus-rigid a second
//       way (a rigid rest gives both vertices the same displacement; the
//       capture measured a 4.8x spread inside one evaluation).
//
// Tolerances: the query pixel is an INT (`cast(int)` in the callers, `+0.5f`
// pixel centre inside), so the query point carries up to ~1px of world
// wobble — 0.0124 world units on this camera. Both bands below are set well
// above that and still an order of magnitude under every refuted rival.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import math : normalize, cross;
    import snap : setBackgroundSnapSources;
    import std.math : abs, cos, sin, PI;
    import std.format : format;

    auto t    = new TopologyPenTool();
    auto view = new View(0, 0, 200, 200);
    Viewport vp = view.viewport();
    scope(exit) setBackgroundSnapSources(null, null);

    // Camera basis straight off the view matrix (column-major m[row+col*4]),
    // so the rig is stated in SCREEN terms exactly like the capture's was.
    Vec3 camRight = Vec3( vp.view[0],  vp.view[4],  vp.view[8]);
    Vec3 camUp    = Vec3( vp.view[1],  vp.view[5],  vp.view[9]);
    Vec3 camFwd   = Vec3(-vp.view[2], -vp.view[6], -vp.view[10]);

    enum float D = 3.0f;   // source depth = this View's own default distance
    enum float L = 2.0f;   // source edge length, screen-horizontal
    Vec3 srcMid = vp.eye + camFwd * D;
    Vec3 v0 = srcMid - camRight * (L * 0.5f);
    Vec3 v1 = srcMid + camRight * (L * 0.5f);

    ImVec2 p0, p1;
    assert(TopologyPenTool.projectWorldPt(v0, vp, p0)
        && TopologyPenTool.projectWorldPt(v1, vp, p1),
        "setup: both source verts must project on-screen");

    foreach (degrees; [30.0f, 45.0f, 60.0f]) {
        immutable float th = degrees * cast(float)PI / 180.0f;

        // Tilt about the screen-vertical axis; place the facet 0.22 D behind
        // the source plane (cell A's own separation).
        Vec3 n     = normalize(camFwd * cos(th) + camRight * sin(th));
        Vec3 bgPt  = vp.eye + camFwd * (D * 1.22f);
        Vec3 inU   = normalize(cross(n, camUp));
        Vec3 inW   = normalize(cross(n, inU));
        enum float H = 40.0f;   // large enough that no foot is ever clamped here

        auto bg = new Mesh();
        bg.vertices = [bgPt - inU * H - inW * H, bgPt + inU * H - inW * H,
                       bgPt + inU * H + inW * H, bgPt - inU * H + inW * H];
        bg.faces    = [[0u, 1u, 2u, 3u]];
        const(Mesh)*[] srcs = [cast(const(Mesh)*) bg];
        import math : ModelSpace;
        setBackgroundSnapSources(srcs, new ModelSpace[](srcs.length));

        Vec3 got0, got1;
        assert(t.resnapToBackground(v0, cast(int)p0.x, cast(int)p0.y, vp, got0),
            format("tilt %.0f: v0 must re-snap onto the background", degrees));
        assert(t.resnapToBackground(v1, cast(int)p1.x, cast(int)p1.y, vp, got1),
            format("tilt %.0f: v1 must re-snap onto the background", degrees));

        // (a) ON the background plane.
        assert(abs(dot(got0 - bgPt, n)) < 1e-4f && abs(dot(got1 - bgPt, n)) < 1e-4f,
            format("tilt %.0f: both targets must lie ON the background plane; "
                 ~ "d0=%g d1=%g", degrees, dot(got0 - bgPt, n), dot(got1 - bgPt, n)));

        // (b) the capture's scored invariant.
        immutable float ratio = (got1 - got0).length / L;
        assert(abs(ratio - cos(th)) < 0.02f,
            format("tilt %.0f: |new|/|src| must be cos(tilt)=%.6f (a camera-ray re-snap "
                 ~ "gives ~1.8/2.5/4.4, every rigid law gives 1.000); got %.6f",
                   degrees, cos(th), ratio));

        // (c) the perpendicular foot, per vertex, derived here.
        Vec3 foot0 = v0 - n * dot(v0 - bgPt, n);
        Vec3 foot1 = v1 - n * dot(v1 - bgPt, n);
        assert((got0 - foot0).length < 0.05f && (got1 - foot1).length < 0.05f,
            format("tilt %.0f: each target must be its OWN source vertex's perpendicular "
                 ~ "foot; got %s/%s expected %s/%s", degrees, got0, got1, foot0, foot1));
    }

    // No background at all -> must report a miss cleanly, and the callers'
    // keep-the-original policy then leaves the gesture a rigid translate
    // (cell A2-NOBG: the duplicate is still created and moved rigidly).
    setBackgroundSnapSources(null, null);
    Vec3 gotNone;
    assert(!t.resnapToBackground(v0, cast(int)p0.x, cast(int)p0.y, vp, gotNone),
        "resnapToBackground must return false with no background source at all");
}

// ---------------------------------------------------------------------------
// resnapToBackground — TASK 0503, THE SAME LAW ON A FLAT BACKGROUND.
//
// Cell A0-FLAT exists because the divergence is NOT an exotic-background
// corner case: on the flat background every earlier cell in this campaign
// used, the reference measured |new|/|src| = 0.999999851 while a camera-ray
// re-snap onto a plane 0.22 D behind the source plane scales the edge by
// exactly that depth ratio — 1.220. This fixture reproduces those two
// numbers, so the ray law is refuted by 0.22 on the friendliest possible
// geometry.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import snap : setBackgroundSnapSources;
    import std.math : abs;
    import std.format : format;

    auto t    = new TopologyPenTool();
    auto view = new View(0, 0, 200, 200);
    Viewport vp = view.viewport();
    scope(exit) setBackgroundSnapSources(null, null);

    Vec3 camRight = Vec3( vp.view[0],  vp.view[4],  vp.view[8]);
    Vec3 camUp    = Vec3( vp.view[1],  vp.view[5],  vp.view[9]);
    Vec3 camFwd   = Vec3(-vp.view[2], -vp.view[6], -vp.view[10]);

    enum float D = 3.0f, L = 2.0f;
    Vec3 srcMid = vp.eye + camFwd * D;
    Vec3 v0 = srcMid - camRight * (L * 0.5f);
    Vec3 v1 = srcMid + camRight * (L * 0.5f);

    Vec3 bgPt = vp.eye + camFwd * (D * 1.22f);   // parallel to the image plane
    enum float H = 40.0f;
    auto bg = new Mesh();
    bg.vertices = [bgPt - camRight * H - camUp * H, bgPt + camRight * H - camUp * H,
                   bgPt + camRight * H + camUp * H, bgPt - camRight * H + camUp * H];
    bg.faces    = [[0u, 1u, 2u, 3u]];
    const(Mesh)*[] srcs = [cast(const(Mesh)*) bg];
    import math : ModelSpace;
    setBackgroundSnapSources(srcs, new ModelSpace[](srcs.length));

    ImVec2 p0, p1;
    assert(TopologyPenTool.projectWorldPt(v0, vp, p0)
        && TopologyPenTool.projectWorldPt(v1, vp, p1), "setup: both verts must project on-screen");

    Vec3 got0, got1;
    assert(t.resnapToBackground(v0, cast(int)p0.x, cast(int)p0.y, vp, got0));
    assert(t.resnapToBackground(v1, cast(int)p1.x, cast(int)p1.y, vp, got1));

    immutable float ratio = (got1 - got0).length / L;
    assert(abs(ratio - 1.0f) < 0.02f,
        format("on a flat background the edge length must be PRESERVED (reference 1.000); "
             ~ "a camera-ray re-snap onto a plane 0.22 D behind scales it to 1.220; got %.6f",
               ratio));

    // And the displacement is a PURE depth shift: no lateral component (the
    // ray law spreads the pair apart by 0.22*L/2 = 0.22 per vertex).
    assert(abs(dot(got0 - v0, camRight)) < 0.05f && abs(dot(got1 - v1, camRight)) < 0.05f,
        format("the flat-background correction must be perpendicular (no lateral slide); "
             ~ "got %g / %g", dot(got0 - v0, camRight), dot(got1 - v1, camRight)));
}

// ---------------------------------------------------------------------------
// perVertexTargets — SHIFT + THE MISS POLICY AFTER TASK 0503.
//
// A shared screen-delta is still applied to EACH vertex's own screen
// projection before re-snapping (the shared-3D-offset shape the reference
// uses is recorded as an open divergence — see `shiftedLocalPoint`). What
// changed is what a vertex pointing at empty space does: a camera ray MISSED
// and the vertex kept its original position; a nearest-foot query over a
// bounded facet does not miss, it CLAMPS to the facet edge. That clamp is
// measured — cell A3-CLIP shortened the background so both feet fell past
// its edge and both new vertices landed exactly on the cut (beta = -0.30000),
// which refutes "keep the original" (they had moved 0.913 and 0.943), "fall
// back to the drag plane" and "refuse the gesture" in one row.
//
// So this pins BOTH halves: a vertex over the patch lands on it, a vertex far
// outside the patch's footprint lands on the patch BOUNDARY (not back at its
// original position), and the keep-the-original branch survives only for the
// no-background case.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import snap : setBackgroundSnapSources;
    import std.math : abs;
    import std.format : format;

    auto t    = new TopologyPenTool();
    auto view = new View(0, 0, 200, 200);
    Viewport vp = view.viewport();
    scope(exit) setBackgroundSnapSources(null, null);

    Vec3 camRight = Vec3( vp.view[0],  vp.view[4],  vp.view[8]);
    Vec3 camUp    = Vec3( vp.view[1],  vp.view[5],  vp.view[9]);
    Vec3 camFwd   = Vec3(-vp.view[2], -vp.view[6], -vp.view[10]);

    enum float D = 3.0f;
    Vec3 vA = vp.eye + camFwd * D;                        // on the patch's axis
    Vec3 vB = vA + camRight * 4.0f;                       // far outside its footprint

    Mesh m;
    m.addVertex(vA);
    m.addVertex(vB);
    t.meshSrc_ = () => &m;

    // A SMALL patch, parallel to the image plane, 0.5 behind vA.
    Vec3 bgPt = vA + camFwd * 0.5f;
    enum float half = 0.6f;
    auto bg = new Mesh();
    bg.vertices = [bgPt - camRight * half - camUp * half, bgPt + camRight * half - camUp * half,
                   bgPt + camRight * half + camUp * half, bgPt - camRight * half + camUp * half];
    bg.faces    = [[0u, 1u, 2u, 3u]];
    const(Mesh)*[] srcs = [cast(const(Mesh)*) bg];
    import math : ModelSpace;
    setBackgroundSnapSources(srcs, new ModelSpace[](srcs.length));

    auto targets = t.perVertexTargets([0u, 1u], 0, 0, vp);
    assert(targets.length == 2);

    // vA: straight onto the patch, a pure depth shift.
    assert(abs(dot(targets[0] - bgPt, camFwd)) < 1e-4f
        && abs(dot(targets[0] - vA, camRight)) < 0.05f,
        format("vA must land ON the patch, perpendicular to it; got %s", targets[0]));

    // vB: CLAMPED to the patch's own boundary, NOT left where it started.
    assert((targets[1] - vB).length > 1.0f,
        format("vB must NOT keep its original position — a nearest-foot query clamps to the "
             ~ "facet instead of missing (cell A3-CLIP); got %s vs original %s",
               targets[1], vB));
    assert(abs(dot(targets[1] - bgPt, camFwd)) < 1e-4f,
        "vB's clamped target must still lie in the patch's own plane");
    assert(abs(abs(dot(targets[1] - bgPt, camRight)) - half) < 1e-4f,
        format("vB must land exactly on the patch's near EDGE (|lateral| == %.2f); got %g",
               half, dot(targets[1] - bgPt, camRight)));

    // With NO background at all, both keep their exact original positions.
    setBackgroundSnapSources(null, null);
    auto none = t.perVertexTargets([0u, 1u], 0, 0, vp);
    assert((none[0] - vA).length < 1e-6f && (none[1] - vB).length < 1e-6f,
        "with no background source the keep-the-original branch must still hold");
}

// ---------------------------------------------------------------------------
// onMoveLoopRmbDown — ARM + CONSUME on a valid seed edge; MISS does not
// consume/arm (doc/topopen_p10_moveloop_plan.md "RMB-dispatch resolution":
// a miss must fall through to RMB-lasso unchanged).
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import mesh : makeGridPlane;
    import toolpipe.packets : SubjectPacket;
    import std.format : format;

    auto t    = new TopologyPenTool();
    auto view = new View(0, 0, 100, 100);
    Mesh m = makeGridPlane(2);
    t.meshSrc_ = () => &m;

    Viewport vp = view.viewport();
    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    ImVec2 p3, p4;
    assert(TopologyPenTool.projectWorldPt(m.vertices[3], vp, p3));
    assert(TopologyPenTool.projectWorldPt(m.vertices[4], vp, p4));
    int mx = cast(int)((p3.x + p4.x) * 0.5f), my = cast(int)((p3.y + p4.y) * 0.5f);

    SDL_MouseButtonEvent eHit;
    eHit.button = SDL_BUTTON_RIGHT;
    eHit.x = mx; eHit.y = my;
    bool consumed = t.onMoveLoopRmbDown(eHit, vts);
    assert(consumed, "a press on a valid edge midpoint must arm and consume");
    assert(t.moveLoopArmed_, "must arm the Move Loop gesture");
    assert(t.moveLoopVerts_ == [3u, 4u, 5u],
        format("armed moving-set must be the in-line row chain; got %s", t.moveLoopVerts_));

    t.moveLoopArmed_ = false;   // reset for the miss probe below
    SDL_MouseButtonEvent eMiss;
    eMiss.button = SDL_BUTTON_RIGHT;
    eMiss.x = -5000; eMiss.y = -5000;   // far from every edge
    bool missConsumed = t.onMoveLoopRmbDown(eMiss, vts);
    assert(!missConsumed, "a press far from every edge must NOT consume");
    assert(!t.moveLoopArmed_, "a miss must not arm the gesture");
}

// ---------------------------------------------------------------------------
// onMouseButtonUp — RIGHT-branch MIN-DRAG (doc/topopen_p10_moveloop_plan.md
// Phase 3): a RMB release within `kMinDragPx` of the press pixel is a clean
// no-op — no vertex write, no undo entry — driven through the extracted
// `moveLoopUp` release-side helper directly (arming state set up directly,
// mirroring P7 Slide's own MIN-DRAG test) so the min-drag GATE ITSELF is
// under test, not just `commitMoveLoop`'s own (also-present) eps guard.
// Phase-2 input-dispatch migration (doc/topopen_input_dispatch_phase2_plan.md,
// Testing Category C): calls `moveLoopUp` directly rather than
// `onMouseButtonUp` — see the Slide MIN-DRAG test's own doc comment above
// for why (the flipped `onMouseButtonUp` keys on the base's private
// `armed_[button]`, set only by a real Down, not on `moveLoopArmed_` this
// test sets directly).
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import mesh : makeGridPlane;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_            = history;
    t.moveLoopEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                       "mesh.topoPen_moveloop", "Topology Move Loop",
                                                       MeshEditScope.Position);

    Mesh m = makeGridPlane(2);
    t.meshSrc_ = () => &m;

    uint seed = m.edgeIndex(3, 4);
    t.moveLoopSeed_   = cast(int)seed;
    t.moveLoopArmed_  = true;
    t.moveLoopStartX_ = 50;
    t.moveLoopStartY_ = 50;
    t.moveLoopVerts_  = [3u, 4u, 5u];

    auto before = MeshSnapshot.capture(m);
    SDL_MouseButtonEvent e;
    e.button = SDL_BUTTON_RIGHT;
    e.x = 51; e.y = 50;   // 1px away — well inside kMinDragPx
    VectorStack vts;
    bool consumed = t.moveLoopUp(e, vts);
    auto after = MeshSnapshot.capture(m);

    assert(consumed, "a click-without-drag release must still consume the event");
    assert(!t.moveLoopArmed_, "release must disarm Move Loop regardless of the min-drag gate");
    assert(after.vertices == before.vertices, "click-without-drag must not move any vertex");
    assert(!history.canUndo(), "click-without-drag must record NO undo entry");
}

// ---------------------------------------------------------------------------
// resyncSession — clears a stray Move Loop arm (doc/topopen_p10_moveloop_plan.md
// "Undo factory"): an external history navigation mid-drag must not leave a
// dangling seed/moving-set for the eventual (now stale) release to commit
// against.
// ---------------------------------------------------------------------------
unittest {
    auto t = new TopologyPenTool();
    t.moveLoopArmed_ = true;
    t.moveLoopSeed_  = 3;
    t.moveLoopVerts_ = [3u, 4u, 5u];

    t.resyncSession();

    assert(!t.moveLoopArmed_, "resyncSession must clear the armed Move Loop gesture");
    assert(t.moveLoopSeed_ == -1, "resyncSession must reset the seed index");
    assert(t.moveLoopVerts_.length == 0, "resyncSession must clear the moving-set");
}

// ---------------------------------------------------------------------------
// toolStateJson — Move Loop fields (doc/topopen_p10_moveloop_plan.md
// Phase 4): reports the armed seed + moving-set size, for Tier-C tests to
// assert the picked seed edge without driving a full release.
// ---------------------------------------------------------------------------
unittest {
    import std.json : JSONType;

    auto t = new TopologyPenTool();

    auto s0 = t.toolStateJson();
    assert(s0["moveLoopArmed"].type == JSONType.false_, "must start with no armed Move Loop");
    assert(cast(int)s0["moveLoopSeed"].integer == -1, "must start with seed=-1");
    assert(cast(int)s0["moveLoopVertCount"].integer == 0, "must start with an empty moving-set");

    t.moveLoopArmed_ = true;
    t.moveLoopSeed_  = 7;
    t.moveLoopVerts_ = [1u, 2u, 3u, 4u];

    auto s1 = t.toolStateJson();
    assert(s1["moveLoopArmed"].type == JSONType.true_, "must report the armed state");
    assert(cast(int)s1["moveLoopSeed"].integer == 7, "must report the picked seed edge");
    assert(cast(int)s1["moveLoopVertCount"].integer == 4, "must report the gathered moving-set size");
}

// ---------------------------------------------------------------------------
// onMouseButtonDown / onMouseMotion / onMouseButtonUp — MANDATORY DISPATCH
// (P10, doc/topopen_p10_moveloop_plan.md): drives the REAL RMB gesture
// end-to-end — dispatch (`onMouseButtonDown` -> `dispatchInput` ->
// `PenGesture.MoveLoop` -> `onMoveLoopRmbDown`), a motion event, and the
// RIGHT-button release branch
// (-> `commitMoveLoop`) — against a REAL background mesh
// (`setBackgroundSnapSources`, CPU-only BVH raycast, no GL context needed),
// so this is a genuine end-to-end proof (not just the mutation, as the
// Tier-B `commitMoveLoop` cases above already cover, nor just the dispatch
// wiring, as `onMoveLoopRmbDown`'s own test above covers) — all still
// pure-`dub test`.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import mesh : makeGridPlane;
    import toolpipe.packets : SubjectPacket;
    import snap : setBackgroundSnapSources;
    import std.math : abs;
    import std.format : format;

    loadSDL();
    SDL_SetModState(cast(SDL_Keymod)0);

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 200, 200);
    auto history = new CommandHistory();
    t.history_            = history;
    t.moveLoopEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                       "mesh.topoPen_moveloop", "Topology Move Loop",
                                                       MeshEditScope.Position);

    Mesh m = makeGridPlane(2);
    t.meshSrc_ = () => &m;

    Viewport vp = view.viewport();

    // A flat background plane well BELOW the primary grid, large enough
    // that every loop vertex's shifted ray lands on it regardless of the
    // exact drag delta chosen below.
    enum float planeY = -1.5f;
    auto bg = new Mesh();
    bg.vertices = [Vec3(-20, planeY, -20), Vec3(20, planeY, -20),
                   Vec3(20, planeY, 20),   Vec3(-20, planeY, 20)];
    bg.faces    = [[0u, 1u, 2u, 3u]];
    const(Mesh)*[] srcs = [cast(const(Mesh)*) bg];
    import math : ModelSpace;
    setBackgroundSnapSources(srcs, new ModelSpace[](srcs.length));
    scope(exit) setBackgroundSnapSources(null, null);

    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    ImVec2 p3, p4;
    assert(TopologyPenTool.projectWorldPt(m.vertices[3], vp, p3));
    assert(TopologyPenTool.projectWorldPt(m.vertices[4], vp, p4));
    int mx = cast(int)((p3.x + p4.x) * 0.5f), my = cast(int)((p3.y + p4.y) * 0.5f);

    SDL_MouseButtonEvent eDown;
    eDown.button = SDL_BUTTON_RIGHT;
    eDown.x = mx; eDown.y = my;
    bool downConsumed = t.onMouseButtonDown(eDown, vts);
    assert(downConsumed, "RMB-down on the seed edge must be consumed via the real dispatch");
    assert(t.moveLoopArmed_, "the real dispatch must have armed Move Loop");

    SDL_MouseMotionEvent eMove;
    eMove.x = mx + 12; eMove.y = my - 7;
    bool moveConsumed = t.onMouseMotion(eMove, vts);
    assert(moveConsumed, "motion while armed must be consumed");

    size_t vBefore = m.vertices.length, eBefore = m.edges.length, fBefore = m.faces.length;
    Vec3[] origPos;
    foreach (vi; [3u, 4u, 5u]) origPos ~= m.vertices[vi];

    SDL_MouseButtonEvent eUp;
    eUp.button = SDL_BUTTON_RIGHT;
    eUp.x = mx + 12; eUp.y = my - 7;
    bool upConsumed = t.onMouseButtonUp(eUp, vts);
    assert(upConsumed, "RMB-up must be consumed");
    assert(!t.moveLoopArmed_, "release must disarm Move Loop regardless of outcome");

    assert(m.vertices.length == vBefore && m.edges.length == eBefore && m.faces.length == fBefore,
        "Move Loop must never change topology (δ=0)");
    assert(history.canUndo(), "the real dispatch path must record one undo entry");

    foreach (i, vi; [3u, 4u, 5u]) {
        assert((m.vertices[vi] - origPos[i]).length > 1e-3f,
            format("loop vertex %d must have actually moved", vi));
        assert(abs(m.vertices[vi].y - planeY) < 0.05f,
            format("loop vertex %d must land ON the background plane (y~=%f); got y=%f",
                   vi, planeY, m.vertices[vi].y));
    }

    SDL_SetModState(cast(SDL_Keymod)0);   // leave the shared SDL modifier global clean
}

// ---------------------------------------------------------------------------
// Generic Hover-Highlight (doc/topopen_hover_highlight_plan.md) — Phase 5
// pure, GL-free unittests (U1-U7) + the `anyGestureArmed()` Tier-A pin.
//
// Two hand-derived test cameras (mirroring `math.d`'s own `makeTestViewport`/
// `constraint.d`'s `makeHoverTestViewport` convention — a `version(unittest)`
// private Viewport builder local to this module): `makeHoverIndicatorTestViewport`
// looks down -Z at the XY plane (for hand-built vertex/edge fixtures, U1/U2/
// U5/U6/U7); `makeGridPlaneTestViewport` looks down -Y at the XZ plane (for
// `makeGridPlane`'s own ground-plane layout, U3/U4). Every test derives its
// cursor pixel via `TopologyPenTool.projectPt` on the mesh's OWN vertices
// (the same technique the P10 dispatch test above uses,
// `(p3.x+p4.x)*0.5f` etc.) rather than hand-computed screen math — exact
// regardless of perspective distortion, and robust to either camera choice.
// ---------------------------------------------------------------------------

version (unittest) private Viewport makeHoverIndicatorTestViewport() {
    import math : lookAt, perspectiveMatrix;
    import std.math : PI;
    Viewport vp;
    vp.eye    = Vec3(0, 0, 5);
    vp.view   = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
    vp.proj   = perspectiveMatrix(PI / 2, 1.0f, 0.1f, 100.0f);
    vp.width  = 800;
    vp.height = 800;
    vp.x = 0;
    vp.y = 0;
    return vp;
}

/// A SNAP configuration with the master enable ON, at the stage's own default
/// ranges — heap-allocated so it can be pushed onto a `VectorStack` that
/// outlives the expression.
///
/// Task 0523. The pen's snap target is gated on this flag now, so a rig that
/// wants to exercise a WELD has to say that snapping is on; a rig that pushes
/// no `SnapPacket` at all is a rig with snapping OFF, and it will get no weld.
/// That is not a testing inconvenience to route around — it is the behaviour
/// under test, and the rigs that call this are the ones whose subject is what
/// the pen does when it DOES land on a vertex. The rigs that assert a no-op
/// deliberately do not call it.
version (unittest) private SnapPacket* penTestSnapOn() {
    auto p = new SnapPacket;
    p.enabled = true;
    return p;
}

version (unittest) private Viewport makeGridPlaneTestViewport() {
    import math : lookAt, perspectiveMatrix;
    import std.math : PI;
    Viewport vp;
    vp.eye    = Vec3(0, 5, 0);
    vp.view   = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 0, -1));
    vp.proj   = perspectiveMatrix(PI / 2, 1.0f, 0.1f, 100.0f);
    vp.width  = 800;
    vp.height = 800;
    vp.x = 0;
    vp.y = 0;
    return vp;
}

/// The same camera on the OTHER side of the plane — eye at -Y, everything
/// else identical (same distance, same FOV, same 800x800, so a grid cell is
/// still 80 px).
///
/// It exists because of a measured fact about `makeGridPlane` that is easy to
/// get backwards: the quads that factory emits have a normal of **-Y**. The
/// traversal `(i,j) → (i,j+1) → (i+1,j+1) → (i+1,j)` gives a Newell (and
/// first-triangle cross) normal of exactly `(0, -2, 0)` on a `makeGridPlane(2)`
/// cell — computed, not assumed. So `makeGridPlaneTestViewport` above, at +Y,
/// looks at the BACK of that plane.
///
/// That did not matter while nothing in the pen tested orientation. It matters
/// now: `backFace` (task 0538) refuses a back-facing snap candidate at its
/// measured default, so a snap-target rig on the +Y camera would produce its
/// expected no-op for the WRONG reason and its expected landing not at all.
/// Rigs whose subject is the snap target therefore look from the side the
/// polygons face. Rigs whose subject is something else (hover resolution,
/// dispatch routing) keep the +Y camera — they never reach this gate.
///
/// The alternative — reversing `makeGridPlane`'s winding — was rejected on
/// purpose: that factory is production code with 200+ call sites (scene reset,
/// the perf meshes, falloff and symmetry fixtures), and flipping its normals
/// to fix a test camera would be a mesh-wide behaviour change smuggled in as a
/// test edit.
version (unittest) private Viewport makeGridPlaneFrontViewport() {
    import math : lookAt, perspectiveMatrix;
    import std.math : PI;
    Viewport vp;
    vp.eye    = Vec3(0, -5, 0);
    vp.view   = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 0, -1));
    vp.proj   = perspectiveMatrix(PI / 2, 1.0f, 0.1f, 100.0f);
    vp.width  = 800;
    vp.height = 800;
    vp.x = 0;
    vp.y = 0;
    return vp;
}

unittest { // U1 — nearest-vertex resolution: a cursor at vertex 0's own
           // projected pixel must resolve `hoverNearestVert_ == 0`,
           // independent of any farther vertex.
    auto t = new TopologyPenTool();
    Mesh m;
    t.meshSrc_ = () => &m;

    uint v0 = m.addVertex(Vec3(0, 0, 0));
    uint v1 = m.addVertex(Vec3(2, 0, 0));
    uint v2 = m.addVertex(Vec3(0, 2, 0));
    m.addEdge(v0, v1);

    auto vp = makeHoverIndicatorTestViewport();
    ImVec2 p0;
    assert(TopologyPenTool.projectWorldPt(m.vertices[v0], vp, p0), "setup: v0 must project on-screen");

    t.computeHoverIndicator(cast(int)p0.x, cast(int)p0.y, vp);
    assert(t.hoverNearestVert_ == cast(int)v0,
        "cursor at v0's own projected pixel must resolve v0 as nearest");
}

unittest { // U2 — nearest-edge resolution: a cursor at an edge's screen
           // midpoint (far from every vertex) must resolve
           // `hoverNearestEdge_` to that edge; `hoverNearestVert_` must
           // ALSO resolve simultaneously (both present, never
           // one-or-the-other).
    auto t = new TopologyPenTool();
    Mesh m;
    t.meshSrc_ = () => &m;

    uint v0 = m.addVertex(Vec3(0, 0, 0));
    uint v1 = m.addVertex(Vec3(2, 0, 0));
    uint v2 = m.addVertex(Vec3(0, 5, 0));   // far away: keeps v0/v1 the two nearest verts
    m.addEdge(v0, v1);
    m.addEdge(v1, v2);   // a second, much farther edge — the pick must not be trivial

    auto vp = makeHoverIndicatorTestViewport();
    ImVec2 p0, p1;
    assert(TopologyPenTool.projectWorldPt(m.vertices[v0], vp, p0));
    assert(TopologyPenTool.projectWorldPt(m.vertices[v1], vp, p1));
    int mx = cast(int)((p0.x + p1.x) * 0.5f);
    int my = cast(int)((p0.y + p1.y) * 0.5f);

    uint expectEdge = m.edgeIndex(v0, v1);
    assert(expectEdge != uint.max, "setup: edge v0-v1 must exist");

    t.computeHoverIndicator(mx, my, vp);
    assert(t.hoverNearestEdge_ == cast(int)expectEdge,
        "cursor at the v0-v1 midpoint must resolve that edge as nearest");
    assert(t.hoverNearestVert_ >= 0,
        "the nearest vertex must ALSO resolve simultaneously");
}

unittest { // U3 — boundary detection: `makeGridPlane(2)`'s edge 0-1 (a
           // genuine top-row perimeter edge, exactly one incident face) must
           // resolve `hoverBoundary_==true` and `hoverBoundaryFace_==` that
           // single incident face — cross-checked independently via
           // `isEdgeBorder`/`facesAroundEdge` (not via the code under test).
    import mesh : makeGridPlane;

    auto t = new TopologyPenTool();
    Mesh m = makeGridPlane(2);   // 3x3 verts (0..8), 4 quads, 12 edges
    t.meshSrc_ = () => &m;

    uint e01 = m.edgeIndex(0, 1);
    assert(e01 != uint.max, "setup: boundary edge 0-1 must exist");
    assert(m.isEdgeBorder(e01), "setup: edge 0-1 must be a genuine boundary edge");
    int expectFace = -1;
    foreach (fi; m.facesAroundEdge(e01)) { expectFace = cast(int)fi; break; }
    assert(expectFace >= 0, "setup: a boundary edge must have exactly one incident face");

    auto vp = makeGridPlaneTestViewport();
    ImVec2 p0, p1;
    assert(TopologyPenTool.projectWorldPt(m.vertices[0], vp, p0));
    assert(TopologyPenTool.projectWorldPt(m.vertices[1], vp, p1));
    int mx = cast(int)((p0.x + p1.x) * 0.5f);
    int my = cast(int)((p0.y + p1.y) * 0.5f);

    t.computeHoverIndicator(mx, my, vp);
    assert(t.hoverNearestEdge_ == cast(int)e01,
        "cursor at the edge-0-1 midpoint must resolve edge 0-1 as nearest");
    assert(t.hoverBoundary_, "edge 0-1 must be classified as a boundary edge");
    assert(t.hoverBoundaryFace_ == expectFace,
        "the hatch face must be the edge's own single incident face");
}

unittest { // U4 — interior (non-boundary) edge: `makeGridPlane(2)`'s edge
           // 3-4 is shared by two cells, so `hoverBoundary_` must resolve
           // false and there is no hatch face.
    import mesh : makeGridPlane;

    auto t = new TopologyPenTool();
    Mesh m = makeGridPlane(2);   // 3x3 verts (0..8), 4 quads, 12 edges
    t.meshSrc_ = () => &m;

    uint e34 = m.edgeIndex(3, 4);
    assert(e34 != uint.max, "setup: interior edge 3-4 must exist");
    assert(!m.isEdgeBorder(e34), "setup: edge 3-4 must be a genuine interior (shared) edge");

    auto vp = makeGridPlaneTestViewport();
    ImVec2 p3, p4;
    assert(TopologyPenTool.projectWorldPt(m.vertices[3], vp, p3));
    assert(TopologyPenTool.projectWorldPt(m.vertices[4], vp, p4));
    int mx = cast(int)((p3.x + p4.x) * 0.5f);
    int my = cast(int)((p3.y + p4.y) * 0.5f);

    t.computeHoverIndicator(mx, my, vp);
    assert(t.hoverNearestEdge_ == cast(int)e34,
        "cursor at the edge-3-4 midpoint must resolve edge 3-4 as nearest");
    assert(!t.hoverBoundary_, "an interior (2-face) edge must never be classified as a boundary");
    assert(t.hoverBoundaryFace_ == -1, "no hatch face for a non-boundary edge");
}

unittest { // U5 — empty mesh / no `meshSrc_`: must resolve to the all-clear
           // state with no crash, whether the delegate itself is unset or
           // wired to a genuinely empty mesh.
    auto vp = makeHoverIndicatorTestViewport();

    auto t1 = new TopologyPenTool();   // fresh tool: meshSrc_ unset (null delegate)
    t1.computeHoverIndicator(400, 400, vp);
    assert(t1.hoverNearestVert_ == -1 && t1.hoverNearestEdge_ == -1 && !t1.hoverBoundary_,
        "no meshSrc_ at all must resolve to the all-clear state");

    auto t2 = new TopologyPenTool();
    Mesh m2;                            // meshSrc_ wired, but the mesh itself is empty
    t2.meshSrc_ = () => &m2;
    t2.computeHoverIndicator(400, 400, vp);
    assert(t2.hoverNearestVert_ == -1 && t2.hoverNearestEdge_ == -1 && !t2.hoverBoundary_,
        "an empty mesh must also resolve to the all-clear state");
}

unittest { // U6 — both-simultaneous ("not one-or-the-other" guard): the
           // nearest vertex and nearest edge resolve INDEPENDENTLY, each to
           // its own pre-known expected index, even when they name entirely
           // unrelated elements — the cursor sits at v0, while the mesh's
           // only edge (v1-v2) is far away and shares no endpoint with v0.
    auto t = new TopologyPenTool();
    Mesh m;
    t.meshSrc_ = () => &m;

    uint v0 = m.addVertex(Vec3(0, 0, 0));      // the cursor's target: nearest VERTEX
    uint v1 = m.addVertex(Vec3(10, 10, 0));    // far away, forms the mesh's ONLY edge
    uint v2 = m.addVertex(Vec3(10, 10.3f, 0));
    m.addEdge(v1, v2);
    uint expectEdge = m.edgeIndex(v1, v2);
    assert(expectEdge != uint.max, "setup: edge v1-v2 must exist");

    auto vp = makeHoverIndicatorTestViewport();
    ImVec2 p0;
    assert(TopologyPenTool.projectWorldPt(m.vertices[v0], vp, p0));

    t.computeHoverIndicator(cast(int)p0.x, cast(int)p0.y, vp);
    assert(t.hoverNearestVert_ == cast(int)v0,
        "nearest vertex must resolve to v0, right under the cursor");
    assert(t.hoverNearestEdge_ == cast(int)expectEdge,
        "nearest edge must ALSO resolve — to the mesh's only edge, v1-v2 — "
      ~ "even though it shares no endpoint with the nearest vertex");
}

unittest { // U7 (REV1 FIX-2 — the test that would have caught FIX-1): a
           // non-null primary with vertices + bare EDGES + ZERO faces (the
           // tool's own from-scratch retopo founding state) must still
           // light up the hover indicator through the REAL `onMouseMotion`
           // gate. `gpu_` stays null (default) so `pickPrimaryFace`
           // short-circuits to -1 unconditionally — exactly mirroring a
           // genuinely faceless mesh's own BVH (zero triangles -> every ray
           // misses), so this proves the gate is NOT driven solely by
           // `pickPrimaryFace >= 0`.
    auto t = new TopologyPenTool();
    Mesh m;
    t.meshSrc_ = () => &m;

    uint v0 = m.addVertex(Vec3(0, 0, 0));
    uint v1 = m.addVertex(Vec3(2, 0, 0));
    m.addEdge(v0, v1);
    assert(m.faces.length == 0, "setup: this fixture must have ZERO faces");

    auto vp = makeHoverIndicatorTestViewport();
    ImVec2 p0;
    assert(TopologyPenTool.projectWorldPt(m.vertices[v0], vp, p0));

    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    SDL_MouseMotionEvent eOn;
    eOn.x = cast(int)p0.x;
    eOn.y = cast(int)p0.y;
    bool consumed = t.onMouseMotion(eOn, vts);
    assert(!consumed, "hover resolution must never consume motion");
    assert(t.hoverOverMesh_,
        "REV1 FIX-1: a faceless/bare-edge primary must still gate 'over the mesh' "
      ~ "via the finite-threshold vertex/edge proximity OR, even though "
      ~ "pickPrimaryFace is unconditionally -1 here");
    assert(t.hoverNearestVert_ == cast(int)v0,
        "the nearest vertex must resolve correctly even in the faceless state");
    assert(t.hoverNearestEdge_ >= 0,
        "the nearest edge must ALSO resolve in the faceless state");

    // A second motion far from all geometry must clear the gate again —
    // proving the gate is a genuine proximity test, not a sticky latch.
    SDL_MouseMotionEvent eOff;
    eOff.x = cast(int)p0.x + 5000;
    eOff.y = cast(int)p0.y + 5000;
    t.onMouseMotion(eOff, vts);
    assert(!t.hoverOverMesh_, "a cursor far from all geometry must clear the over-mesh gate");
    assert(t.hoverNearestVert_ == -1 && t.hoverNearestEdge_ == -1,
        "off-mesh must also clear the resolved nearest indices");
}

unittest { // arm coverage (doc/topopen_hover_highlight_plan.md MINOR-3, task
           // 0705): EVERY arm — by the compiler's own enumeration, not by a
           // list written here — independently flips `anyGestureArmed()` true,
           // and `resetAllGestureArms()` clears it again.
           //
           // The predecessor of this test spelled the flags out one per line
           // and so pinned 10 of the 11 that existed: `dupEdgeArmed_` (task
           // 0485) was in the OR but in no list. Iterating `kGestureArmFields`
           // means the test cannot fall behind the class — a new gesture is
           // covered the moment its field is declared. It also catches the one
           // way the derivation itself could fail silently: if the trait
           // matched nothing, the list would be empty and the length assert
           // below would fire.
    auto t = new TopologyPenTool();
    assert(!t.anyGestureArmed(), "no arm flag set -> false");
    assert(kGestureArmFields.length >= 11,
        "the GestureArm walk must find every declared arm — an empty or short "
        ~ "list means the trait stopped matching and every arm now reads disarmed");

    static foreach (m; kGestureArmFields) {{
        __traits(getMember, t, m) = true;
        assert(t.anyGestureArmed(), m ~ " must count towards anyGestureArmed()");
        t.resetAllGestureArms();
        assert(!t.anyGestureArmed(),
            "resetAllGestureArms() must clear " ~ m);
        assert(!__traits(getMember, t, m).armed,
            "resetAllGestureArms() must clear " ~ m ~ " specifically");
    }}

    assert(!t.anyGestureArmed(), "every flag cleared again -> false");
}

// ===========================================================================
// P11 Duplicate Loop (doc/topopen_p11_duploop_plan.md) — Tier-B in-file
// unittests. The mandatory Phase-0 closed-rim probe (REV1 FIX-1) lives in
// mesh.d itself (`extendEdgesByMask: CLOSED-RING boundary probe`), since it
// pins the KERNEL's own behavior, not this tool. Everything below drives
// `commitDupLoop`/the dispatch handlers directly against hand-built
// `makeGridPlane(2)` fixtures — no bg needed for the topology-delta/
// coincident-vert/undo assertions (dx=dy=0 with no background source ⇒
// every ray misses ⇒ new verts stay exactly coincident, the deterministic
// no-bg case). The on-surface/resnap assertion is Tier-C
// (tests/test_topopen_duploop_resnap.d).
// ===========================================================================

unittest { // commitDupLoop — T1 BOUNDARY (doc/topopen_p11_duploop_plan.md
           // "Testing strategy", the owner-observed/measured case): a
           // CLOSED-perimeter loop (REV1 FIX-1 label correction — a
           // BOUNDARY seed is the FULL closed rim) duplicated with no
           // background (dx=dy=0 -> every ray misses -> new verts stay
           // EXACTLY coincident with their source): topology delta =
           // (+M,+(N+M),+N) computed from the gathered loop itself (not
           // hard-coded); every new (tail) vert coincident with its source
           // loop vert; the M original loop verts UNCHANGED; one history
           // entry; undo restores EXACTLY (removes all new geometry); redo
           // re-applies.
    import view : View;
    import editmode : EditMode;
    import mesh : makeGridPlane;
    import std.format : format;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_            = history;
    t.dupLoopEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                      "mesh.topoPen_duploop", "Topology Duplicate Loop",
                                                      MeshEditScope.Geometry | MeshEditScope.Marks);

    Mesh m = makeGridPlane(2);
    t.meshSrc_ = () => &m;

    uint seed = m.edgeIndex(0, 1);
    auto loop = m.selectLoopEdges(seed);
    assert(loop.length == 8, "boundary seed must gather the full closed 8-edge rim");

    uint[] loopVerts;
    bool[uint] seen;
    foreach (ei; loop) {
        auto ep = m.edges[cast(uint)ei];
        foreach (v; ep) if (v !in seen) { seen[v] = true; loopVerts ~= v; }
    }
    size_t N = loop.length, M = loopVerts.length;
    assert(M == 8, "closed ring: M == N == 8 (one vertex per rim edge)");

    Vec3[] origLoopPos;
    foreach (vi; loopVerts) origLoopPos ~= m.vertices[vi];

    size_t vBefore = m.vertices.length, eBefore = m.edges.length, fBefore = m.faces.length;
    Viewport vp;
    t.commitDupLoop(loop, 0, 0, vp);

    assert(m.vertices.length == vBefore + M,
        format("expected +%d verts, got +%d", M, m.vertices.length - vBefore));
    assert(m.faces.length    == fBefore + N,
        format("expected +%d faces, got +%d", N, m.faces.length - fBefore));
    assert(m.edges.length    == eBefore + N + M,
        format("expected +%d edges, got +%d", N + M, m.edges.length - eBefore));

    // Every new (tail) vert is coincident with SOME original loop vertex —
    // no background -> every ray misses -> perVertexTargets keeps the
    // coincident post-extrude position verbatim.
    foreach (i; vBefore .. m.vertices.length) {
        bool matched = false;
        foreach (op; origLoopPos) if ((m.vertices[i] - op).length < 1e-5f) { matched = true; break; }
        assert(matched, format("new tail vertex %d must be coincident with some original loop vertex", i));
    }

    // The M original loop verts are UNCHANGED.
    foreach (i, vi; loopVerts)
        assert((m.vertices[vi] - origLoopPos[i]).length < 1e-6f,
            "the original loop vertices must never be written by DupLoop");

    assert(history.canUndo(), "a real Dup Loop commit must record one undo entry");

    history.undo();
    assert(m.vertices.length == vBefore && m.edges.length == eBefore && m.faces.length == fBefore,
        "undo must remove every bit of new geometry");
    foreach (i, vi; loopVerts)
        assert((m.vertices[vi] - origLoopPos[i]).length < 1e-6f,
            "undo must leave the original loop verts exactly alone");

    history.redo();
    assert(m.vertices.length == vBefore + M && m.edges.length == eBefore + N + M
        && m.faces.length == fBefore + N,
        "redo must re-apply the exact topology growth");
}

unittest { // commitDupLoop — T2 INTERIOR, FLAGGED (doc/topopen_p11_duploop_plan.md
           // "Out of scope (deferred, flagged)" / REV1 FIX-1 §Open-item IL):
           // an INTERIOR seed resolves to the classic OPEN in-line chain
           // (REV1 label correction), which `extendEdgesByMask` extends into
           // a non-manifold (2->3-face) result — UNMEASURED, the owner did
           // NOT capture this case. This test pins only the well-defined
           // TOPOLOGY DELTA (open-chain M=N+1); manifoldness is
           // DELIBERATELY NOT asserted here.
    import view : View;
    import editmode : EditMode;
    import mesh : makeGridPlane;
    import std.format : format;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_            = history;
    t.dupLoopEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                      "mesh.topoPen_duploop", "Topology Duplicate Loop",
                                                      MeshEditScope.Geometry | MeshEditScope.Marks);

    Mesh m = makeGridPlane(2);
    t.meshSrc_ = () => &m;

    uint seed = m.edgeIndex(3, 4);   // interior seed -> the middle-row open chain
    auto loop = m.selectLoopEdges(seed);
    assert(loop.length == 2, "interior seed must gather the 2-edge open middle-row chain");

    uint[] loopVerts;
    bool[uint] seen;
    foreach (ei; loop) {
        auto ep = m.edges[cast(uint)ei];
        foreach (v; ep) if (v !in seen) { seen[v] = true; loopVerts ~= v; }
    }
    size_t N = loop.length, M = loopVerts.length;
    assert(M == N + 1, "open chain: M == N+1");

    size_t vBefore = m.vertices.length, eBefore = m.edges.length, fBefore = m.faces.length;
    Viewport vp;
    t.commitDupLoop(loop, 0, 0, vp);

    assert(m.vertices.length == vBefore + M,
        format("expected +%d verts, got +%d", M, m.vertices.length - vBefore));
    assert(m.faces.length    == fBefore + N,
        format("expected +%d faces, got +%d", N, m.faces.length - fBefore));
    assert(m.edges.length    == eBefore + N + M,
        format("expected +%d edges, got +%d", N + M, m.edges.length - eBefore));
    assert(history.canUndo(), "a real interior Dup Loop commit must still record one undo entry");
    // Manifoldness NOT asserted -- Open-item IL, unmeasured against the reference.
}

unittest { // commitDupLoop — NO-OP GUARD (doc/topopen_p11_duploop_plan.md
           // "The flow"): a WIRE edge (zero adjacent faces) as the sole
           // gathered loop -- `extendEdgesByMask` skips it (no orienting
           // face to bridge against) and returns 0 -- must be a clean
           // no-op: no mutation, no history entry, `!canUndo`.
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_            = history;
    t.dupLoopEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                      "mesh.topoPen_duploop", "Topology Duplicate Loop",
                                                      MeshEditScope.Geometry | MeshEditScope.Marks);

    Mesh m;
    uint v0 = m.addVertex(Vec3(0, 0, 0));
    uint v1 = m.addVertex(Vec3(1, 0, 0));
    m.addEdge(v0, v1);   // a bare wire edge -- zero adjacent faces
    t.meshSrc_ = () => &m;

    uint seed = m.edgeIndex(v0, v1);
    assert(seed != uint.max);
    auto loop = m.selectLoopEdges(seed);   // a stray/degenerate edge -> [seed] itself
    assert(loop == [cast(int)seed]);

    Viewport vp;
    auto before = MeshSnapshot.capture(m);
    t.commitDupLoop(loop, 5, 5, vp);
    auto after = MeshSnapshot.capture(m);

    assert(after.vertices == before.vertices && m.faces.length == 0,
        "a wire-only loop must produce NO mutation");
    assert(!history.canUndo(), "a wire-only loop must record NO undo entry");
}

unittest { // commitDupLoop — resyncSession-on-success (doc/topopen_p11_duploop_plan.md
           // "Undo factory" KILLER-2): once a real Dup Loop commit lands
           // (topology GREW -- faces[]/edges[]/vertices[] all resized), any
           // OTHER gesture armed on a different button must be invalidated
           // -- its cached index would otherwise dangle against the
           // resized arrays. Mirrors `removeFaceAt`'s/`commitAddLoop`'s own
           // resyncSession()-on-success discipline.
    import view : View;
    import editmode : EditMode;
    import mesh : makeGridPlane;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_            = history;
    t.dupLoopEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                      "mesh.topoPen_duploop", "Topology Duplicate Loop",
                                                      MeshEditScope.Geometry | MeshEditScope.Marks);

    Mesh m = makeGridPlane(2);
    t.meshSrc_ = () => &m;

    uint seed = m.edgeIndex(0, 1);   // boundary seed -> the full closed perimeter
    auto loop = m.selectLoopEdges(seed);
    assert(loop.length == 8);

    // Hand-arm a sibling gesture on a DIFFERENT button, as if it were
    // mid-drag concurrently.
    t.moveLoopArmed_ = true;
    t.moveLoopSeed_  = 3;
    t.moveLoopVerts_ = [3u, 4u, 5u];

    Viewport vp;
    t.commitDupLoop(loop, 0, 0, vp);   // no bg -> every new vert stays coincident; still a real commit

    assert(history.canUndo(), "setup: the commit must have actually recorded an undo entry");
    assert(!t.moveLoopArmed_, "resyncSession() on a successful Dup Loop commit must clear a sibling arm");
}

// ---------------------------------------------------------------------------
// onShiftLmbDown on an EDGE -> arms the single-edge DUPLICATE, not a build
// (task 0485). The reference's Duplicate mode "duplicates an edge as you drag
// it", widening to a loop only under Edge Loop / the right mouse button — so
// this slot has two outcomes, resolved by what the press lands on, and the
// vertex outcome (P3's drag-build) must keep working untouched.
//
// A stationary Shift+click duplicates nothing: same click-vs-drag gate as
// every other gesture here. Driven directly — the no-drag path returns before
// any `gpu_`/GL tail, so it runs under a bare `dub test`.
// ---------------------------------------------------------------------------
unittest {
    import mesh : makeGridPlane;
    import toolpipe.packets : SubjectPacket;

    auto t = new TopologyPenTool();
    Mesh m = makeGridPlane(2);
    t.meshSrc_ = () => &m;

    // Task 0496: the grid-plane viewport (80px per grid cell), not the 100x100
    // `View` default this case used to build. Under that tiny viewport a grid
    // half-edge projected to ~13px, which the pen's press-pick reach could
    // swallow, so the "midpoint resolves no vertex" precondition below could no
    // longer hold. The precondition is the point of the case; the viewport was
    // incidental. Asserted below, so the reach can move again without this
    // case silently turning into a different test.
    auto vp = makeGridPlaneTestViewport();
    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    ImVec2 p0, p1;
    assert(TopologyPenTool.projectWorldPt(m.vertices[m.edges[0][0]], vp, p0), "setup: endpoint projects");
    assert(TopologyPenTool.projectWorldPt(m.vertices[m.edges[0][1]], vp, p1), "setup: endpoint projects");

    // --- EDGE midpoint: no vertex within snap range, so the edge outcome.
    SDL_MouseButtonEvent eEdge;
    eEdge.x = cast(int)((p0.x + p1.x) * 0.5f);
    eEdge.y = cast(int)((p0.y + p1.y) * 0.5f);
    assert(t.findSourceVertex(eEdge.x, eEdge.y, vp) < 0,
        "setup: the midpoint must resolve NO vertex, or this would test the build path");
    immutable int seed = t.findRingSeedEdge(eEdge.x, eEdge.y, vp);
    assert(seed >= 0, "setup: the midpoint must resolve an edge");

    assert(t.onShiftLmbDown(eEdge, vts), "a Shift+LMB press on an edge must be consumed");
    assert(t.dupEdgeArmed_, "it must arm the single-edge duplicate");
    assert(t.dupEdgeSeed_ == seed, "and arm it on the edge the pick resolved");
    assert(!t.dragArmed_, "it must NOT arm P3's vertex drag-build");
    assert(t.anyGestureArmed(), "the new arm must be visible to anyGestureArmed()");

    // A release back at the press pixel is a click, not a drag: no mutation.
    immutable size_t vBefore = m.vertices.length, fBefore = m.faces.length;
    assert(t.buildUp(eEdge, vts), "the release of an armed gesture is consumed");
    assert(!t.dupEdgeArmed_, "the release must disarm");
    assert(m.vertices.length == vBefore && m.faces.length == fBefore,
        "a stationary Shift+click on an edge must duplicate nothing");

    // --- VERTEX: P3's drag-build still owns that outcome, unchanged.
    t.resetAllGestureArms();
    SDL_MouseButtonEvent eVert;
    eVert.x = cast(int)p0.x; eVert.y = cast(int)p0.y;
    assert(t.onShiftLmbDown(eVert, vts), "a Shift+LMB press on a vertex must still be consumed");
    assert(t.dragArmed_, "a vertex press must still arm the drag-build");
    assert(!t.dupEdgeArmed_, "a vertex press must NOT arm the edge duplicate");

    // --- Neither: still declined, so a Shift+LMB on empty space falls through
    // to the host's own sel-add path exactly as before.
    t.resetAllGestureArms();
    SDL_MouseButtonEvent eFar;
    eFar.x = -99999; eFar.y = -99999;
    assert(!t.onShiftLmbDown(eFar, vts), "a press on nothing must stay unconsumed");
    assert(!t.dragArmed_ && !t.dupEdgeArmed_, "and must arm neither outcome");
}

// ---------------------------------------------------------------------------
// The BORDER GATE on Duplicate (task 0486, contract C-0) — the finding that
// re-scoped the whole capture. The reference's Evaluate guards Duplicate on
// `isEdgeBorder(pressed edge)`; when it fails it silently runs MOVE. So an
// interior-edge press through the Duplicate slot is neither a duplicate NOR a
// declined press: Shift+LMB there is a 2-vertex element move, Shift+RMB there
// is a move-loop.
//
// `makeGridPlane(3)` carries both sides of the gate: its rim edges are border
// edges (one incident face) and its inner edges are not (two).
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import mesh : makeGridPlane;
    import toolpipe.packets : SubjectPacket;
    import std.format : format;

    auto t = new TopologyPenTool();
    Mesh m = makeGridPlane(3);
    t.meshSrc_ = () => &m;
    auto vp = makeGridPlaneTestViewport();

    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    // Find one border edge and one interior edge, and the pixel at each midpoint.
    int borderEdge = -1, interiorEdge = -1;
    foreach (ei; 0 .. cast(int)m.edges.length) {
        if (m.isEdgeBorder(cast(uint) ei)) { if (borderEdge < 0) borderEdge = ei; }
        else if (interiorEdge < 0) interiorEdge = ei;
    }
    assert(borderEdge >= 0 && interiorEdge >= 0,
        "setup: a 3x3 grid must carry both a border and an interior edge");

    SDL_MouseButtonEvent pixOf(int ei) {
        ImVec2 pa, pb;
        assert(TopologyPenTool.projectWorldPt(m.vertices[m.edges[ei][0]], vp, pa));
        assert(TopologyPenTool.projectWorldPt(m.vertices[m.edges[ei][1]], vp, pb));
        SDL_MouseButtonEvent ev;
        ev.x = cast(int)((pa.x + pb.x) * 0.5f);
        ev.y = cast(int)((pa.y + pb.y) * 0.5f);
        return ev;
    }

    // --- BORDER side: Shift+LMB duplicates.
    auto eB = pixOf(borderEdge);
    assert(t.findSourceVertex(eB.x, eB.y, vp) < 0,
        "setup: the border midpoint must resolve no vertex, or this tests the vertex outcome");
    assert(t.onShiftLmbDown(eB, vts), "Shift+LMB on a BORDER edge must be consumed");
    assert(t.dupEdgeArmed_, "a border seed must arm the DUPLICATE");
    assert(!t.moveArmed_, "and must not arm a move");

    // --- INTERIOR side, same chord: falls through to a 2-vertex MOVE.
    t.resetAllGestureArms();
    auto eI = pixOf(interiorEdge);
    if (t.findSourceVertex(eI.x, eI.y, vp) < 0 && t.findRingSeedEdge(eI.x, eI.y, vp) == interiorEdge) {
        assert(t.onShiftLmbDown(eI, vts), "Shift+LMB on an INTERIOR edge must still be consumed");
        assert(!t.dupEdgeArmed_,
            "an interior seed must NOT arm a duplicate — the reference gates Duplicate on "
          ~ "isEdgeBorder and silently runs Move instead");
        assert(t.moveArmed_ && t.moveElem_ == MoveElem.Edge,
            "it must arm the EDGE move family instead");
        assert(t.moveVerts_.length == 2,
            format("a 2-vertex move, per the measured interior outcome; got %d",
                   t.moveVerts_.length));

        // The release must reach the MOVE's commit leg, not the build's — the
        // Duplicate slot's UP has to follow where its own DOWN went.
        assert(t.buildUp(eI, vts), "the release after a fall-through must be consumed");
        assert(!t.moveArmed_, "and must disarm the move it actually armed");
    }

    // --- INTERIOR side, Shift+RMB: falls through to a MOVE-LOOP.
    t.resetAllGestureArms();
    if (t.findRingSeedEdge(eI.x, eI.y, vp) == interiorEdge) {
        SDL_MouseButtonEvent eR = eI;
        eR.button = SDL_BUTTON_RIGHT;
        t.onDupLoopShiftRmbDown(eR, vts);
        assert(!t.dupLoopArmed_,
            "Shift+RMB on an interior edge must NOT arm a duplicate-loop");
        assert(t.moveLoopArmed_, "it must arm the MOVE-loop instead");
        assert(t.dupLoopUp(eR, vts),
            "and the release must reach moveLoopUp through the dup-loop UP leg");
    }
}

// ---------------------------------------------------------------------------
// onDupLoopShiftRmbDown — ARM + CONSUME on a valid seed edge; MISS does not
// consume/arm (doc/topopen_p11_duploop_plan.md "Shift+RMB dispatch
// resolution": a miss must fall through to Shift+RMB-lasso unchanged).
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import mesh : makeGridPlane;
    import toolpipe.packets : SubjectPacket;
    import std.format : format;

    auto t    = new TopologyPenTool();
    auto view = new View(0, 0, 100, 100);
    Mesh m = makeGridPlane(2);
    t.meshSrc_ = () => &m;

    Viewport vp = view.viewport();
    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    ImVec2 p0, p1;
    assert(TopologyPenTool.projectWorldPt(m.vertices[0], vp, p0));
    assert(TopologyPenTool.projectWorldPt(m.vertices[1], vp, p1));
    int mx = cast(int)((p0.x + p1.x) * 0.5f), my = cast(int)((p0.y + p1.y) * 0.5f);

    SDL_MouseButtonEvent eHit;
    eHit.button = SDL_BUTTON_RIGHT;
    eHit.x = mx; eHit.y = my;
    bool consumed = t.onDupLoopShiftRmbDown(eHit, vts);
    assert(consumed, "a Shift+RMB press on a valid boundary edge midpoint must arm and consume");
    assert(t.dupLoopArmed_, "must arm the Dup Loop gesture");

    // Task 0486 (contract C-4): the armed set is the trimmed border RUN, not
    // the whole gathered rim. `makeGridPlane(2)` is 2x2 quads, so its rim's
    // four CORNER vertices have a single incident polygon each; the walk from
    // seed 0-1 stops at both of them and keeps the top run {0-1, 1-2}. This
    // assertion used to demand all 8 rim edges — which is exactly the
    // owner-reported "it takes all edges", and what the reference does NOT do
    // (measured 12-gathered -> 3-committed on the 4x4 grid; the run length is
    // the number of quads along that side).
    assert(t.dupLoopEdges_.length == 2,
        format("armed set must be the trimmed 2-edge top run, not the whole rim; got %d edges",
               t.dupLoopEdges_.length));
    foreach (ei; t.dupLoopEdges_) {
        assert(m.isEdgeBorder(cast(uint) ei), "every edge in the run must be a border edge");
        auto ep = m.edges[ei];
        assert(ep[0] <= 2 && ep[1] <= 2,
            "the run must stay on the TOP row (vertices 0-2), never turn a corner");
    }

    t.dupLoopArmed_ = false;   // reset for the miss probe below
    SDL_MouseButtonEvent eMiss;
    eMiss.button = SDL_BUTTON_RIGHT;
    eMiss.x = -5000; eMiss.y = -5000;   // far from every edge
    bool missConsumed = t.onDupLoopShiftRmbDown(eMiss, vts);
    assert(!missConsumed, "a press far from every edge must NOT consume");
    assert(!t.dupLoopArmed_, "a miss must not arm the gesture");
}

// ---------------------------------------------------------------------------
// onMouseButtonUp — RIGHT-branch MIN-DRAG (doc/topopen_p11_duploop_plan.md
// Phase 3): a Shift+RMB release within `kMinDragPx` of the press pixel is a
// clean no-op — no extrude, no undo entry — driven through the extracted
// `dupLoopUp` release-side helper directly (arming state set up directly,
// mirroring P10 Move Loop's own MIN-DRAG test) so the min-drag GATE ITSELF
// is under test. Phase-2 input-dispatch migration
// (doc/topopen_input_dispatch_phase2_plan.md, Testing Category C): calls
// `dupLoopUp` directly rather than `onMouseButtonUp` — see the Slide
// MIN-DRAG test's own doc comment for why.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import mesh : makeGridPlane;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_            = history;
    t.dupLoopEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                      "mesh.topoPen_duploop", "Topology Duplicate Loop",
                                                      MeshEditScope.Geometry | MeshEditScope.Marks);

    Mesh m = makeGridPlane(2);
    t.meshSrc_ = () => &m;

    uint seed = m.edgeIndex(0, 1);
    auto edges = m.selectLoopEdges(seed);
    t.dupLoopSeed_    = cast(int)seed;
    t.dupLoopArmed_   = true;
    t.dupLoopStartX_  = 50;
    t.dupLoopStartY_  = 50;
    t.dupLoopEdges_   = edges;

    auto before = MeshSnapshot.capture(m);
    SDL_MouseButtonEvent e;
    e.button = SDL_BUTTON_RIGHT;
    e.x = 51; e.y = 50;   // 1px away — well inside kMinDragPx
    VectorStack vts;
    bool consumed = t.dupLoopUp(e, vts);
    auto after = MeshSnapshot.capture(m);

    assert(consumed, "a click-without-drag release must still consume the event");
    assert(!t.dupLoopArmed_, "release must disarm Dup Loop regardless of the min-drag gate");
    assert(after.vertices == before.vertices && after.faces.length == before.faces.length,
        "click-without-drag must not mutate the mesh at all");
    assert(!history.canUndo(), "click-without-drag must record NO undo entry");
}

// ---------------------------------------------------------------------------
// resyncSession — clears a stray Dup Loop arm (doc/topopen_p11_duploop_plan.md
// "Undo factory"): an external history navigation mid-drag must not leave a
// dangling seed/edge-list for the eventual (now stale) release to commit
// against.
// ---------------------------------------------------------------------------
unittest {
    auto t = new TopologyPenTool();
    t.dupLoopArmed_ = true;
    t.dupLoopSeed_  = 3;
    t.dupLoopEdges_ = [3, 4];

    t.resyncSession();

    assert(!t.dupLoopArmed_, "resyncSession must clear the armed Dup Loop gesture");
    assert(t.dupLoopSeed_ == -1, "resyncSession must reset the seed index");
    assert(t.dupLoopEdges_.length == 0, "resyncSession must clear the gathered loop-edge list");
}

// ---------------------------------------------------------------------------
// toolStateJson — Dup Loop fields (doc/topopen_p11_duploop_plan.md Phase 4):
// reports the armed seed + gathered loop-edge count, for Tier-C tests to
// assert the picked seed edge without driving a full release.
// ---------------------------------------------------------------------------
unittest {
    import std.json : JSONType;

    auto t = new TopologyPenTool();

    auto s0 = t.toolStateJson();
    assert(s0["dupLoopArmed"].type == JSONType.false_, "must start with no armed Dup Loop");
    assert(cast(int)s0["dupLoopSeed"].integer == -1, "must start with seed=-1");
    assert(cast(int)s0["dupLoopEdgeCount"].integer == 0, "must start with an empty gathered loop");

    t.dupLoopArmed_ = true;
    t.dupLoopSeed_  = 7;
    t.dupLoopEdges_ = [1, 2, 3, 4, 5];

    auto s1 = t.toolStateJson();
    assert(s1["dupLoopArmed"].type == JSONType.true_, "must report the armed state");
    assert(cast(int)s1["dupLoopSeed"].integer == 7, "must report the picked seed edge");
    assert(cast(int)s1["dupLoopEdgeCount"].integer == 5, "must report the gathered loop-edge count");
}

// ---------------------------------------------------------------------------
// onMouseButtonDown / onMouseMotion / onMouseButtonUp — MANDATORY DISPATCH
// (P11, doc/topopen_p11_duploop_plan.md): drives the REAL Shift+RMB gesture
// end-to-end — dispatch (`onMouseButtonDown` -> `dispatchInput` ->
// `PenGesture.DupLoop` ->
// `onDupLoopShiftRmbDown`), a motion event, and the RIGHT-button release
// branch (-> `commitDupLoop`) — against a REAL background mesh
// (`setBackgroundSnapSources`, CPU-only BVH raycast, no GL context needed),
// so this is a genuine end-to-end proof (not just the mutation, as the
// Tier-B `commitDupLoop` cases above already cover, nor just the dispatch
// wiring, as `onDupLoopShiftRmbDown`'s own test above covers) — all still
// pure-`dub test`.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import mesh : makeGridPlane;
    import toolpipe.packets : SubjectPacket;
    import snap : setBackgroundSnapSources;
    import std.math : abs;
    import std.format : format;

    loadSDL();
    SDL_SetModState(KMOD_SHIFT);
    scope(exit) SDL_SetModState(cast(SDL_Keymod)0);   // don't leak into later dub-test unittests

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 200, 200);
    auto history = new CommandHistory();
    t.history_            = history;
    t.dupLoopEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                      "mesh.topoPen_duploop", "Topology Duplicate Loop",
                                                      MeshEditScope.Geometry | MeshEditScope.Marks);

    Mesh m = makeGridPlane(2);
    t.meshSrc_ = () => &m;

    Viewport vp = view.viewport();

    // A flat background plane well BELOW the primary grid, large enough
    // that every new vertex's shifted ray lands on it regardless of the
    // exact drag delta chosen below.
    enum float planeY = -1.5f;
    auto bg = new Mesh();
    bg.vertices = [Vec3(-20, planeY, -20), Vec3(20, planeY, -20),
                   Vec3(20, planeY, 20),   Vec3(-20, planeY, 20)];
    bg.faces    = [[0u, 1u, 2u, 3u]];
    const(Mesh)*[] srcs = [cast(const(Mesh)*) bg];
    import math : ModelSpace;
    setBackgroundSnapSources(srcs, new ModelSpace[](srcs.length));
    scope(exit) setBackgroundSnapSources(null, null);

    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    ImVec2 p0, p1;
    assert(TopologyPenTool.projectWorldPt(m.vertices[0], vp, p0));
    assert(TopologyPenTool.projectWorldPt(m.vertices[1], vp, p1));
    int mx = cast(int)((p0.x + p1.x) * 0.5f), my = cast(int)((p0.y + p1.y) * 0.5f);

    SDL_MouseButtonEvent eDown;
    eDown.button = SDL_BUTTON_RIGHT;
    eDown.x = mx; eDown.y = my;
    bool downConsumed = t.onMouseButtonDown(eDown, vts);
    assert(downConsumed, "Shift+RMB-down on the seed edge must be consumed via the real dispatch");
    assert(t.dupLoopArmed_, "the real dispatch must have armed Dup Loop");
    assert(t.dupLoopEdges_.length == 2,
        "the real dispatch must arm the TRIMMED border run (task 0486 C-4), not the whole rim");

    SDL_MouseMotionEvent eMove;
    eMove.x = mx + 12; eMove.y = my - 7;
    bool moveConsumed = t.onMouseMotion(eMove, vts);
    assert(moveConsumed, "motion while armed must be consumed");

    size_t vBefore = m.vertices.length, eBefore = m.edges.length, fBefore = m.faces.length;

    SDL_MouseButtonEvent eUp;
    eUp.button = SDL_BUTTON_RIGHT;
    eUp.x = mx + 12; eUp.y = my - 7;
    bool upConsumed = t.onMouseButtonUp(eUp, vts);
    assert(upConsumed, "RMB-up must be consumed");
    assert(!t.dupLoopArmed_, "release must disarm Dup Loop regardless of outcome");

    // Task 0486 (contract C-4): the trimmed 2-edge run, not the 8-edge rim.
    // An OPEN run of n edges duplicates to +(n+1) vertices, +(2n+1) edges
    // (n duplicated + n+1 rungs) and +n faces — the same arithmetic the
    // reference was measured at for n=1 (+2/+3/+1) and n=3 (+4/+7/+3). Here
    // n=2, so +3/+5/+2. A CLOSED rim would be +8/+16/+8, which is what this
    // used to assert and what the trim exists to prevent on an open patch.
    assert(m.vertices.length == vBefore + 3 && m.edges.length == eBefore + 5
        && m.faces.length == fBefore + 2,
        format("the real dispatch path must grow by the trimmed 2-edge-run delta "
             ~ "(+3v/+5e/+2f); got (+%d/+%d/+%d)",
               m.vertices.length - vBefore, m.edges.length - eBefore,
               m.faces.length - fBefore));
    assert(history.canUndo(), "the real dispatch path must record one undo entry");

    foreach (vi; vBefore .. m.vertices.length)
        assert(abs(m.vertices[vi].y - planeY) < 0.05f,
            format("new vertex %d must land ON the background plane (y~=%f); got y=%f",
                   vi, planeY, m.vertices[vi].y));

    // The original 9 grid verts must be exactly unchanged.
    Vec3[9] gridPos;
    foreach (i; 0 .. 3) foreach (j; 0 .. 3)
        gridPos[i * 3 + j] = Vec3(-1.0f + cast(float)j, 0.0f, -1.0f + cast(float)i);
    foreach (vi; 0 .. 9)
        assert((m.vertices[vi] - gridPos[vi]).length < 1e-5f,
            format("original grid vertex %d must be left exactly alone", vi));
}

// ===========================================================================
// P12 Smooth+Loop (doc/topopen_p12_smoothloop_plan.md) — Tier-B in-file
// unittests. The relax LAW is the P8-shared kernel extracted above
// (`inverseEdgeLenRelax`); P8's OWN `smoothedRelaxTarget` T4/boundary
// unittests (earlier in this file) already pin the wrapper's behavior and
// stay green unchanged — same direct-call signature, a pure extraction
// (REV1 core-plan approval). This section pins the NEW P12-only surface:
// the extracted kernel called with a RESTRICTED (loop) neighbor set, the
// 1-D loop-neighbor connectivity helper, the commit-level "only loop
// vertices move" + F1 endpoints-held-fixed contracts, dispatch, and undo.
// ===========================================================================

unittest { // inverseEdgeLenRelax — 2-neighbor exact match against an
           // INDEPENDENTLY-computed inverse-edge-length midpoint (mirrors
           // P8's own T4 discriminator, applied here directly to the
           // EXTRACTED kernel rather than through `smoothedRelaxTarget`'s
           // full-1-ring wrapper).
    import std.format : format;

    Vec3[] readPos = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 4, 0)];   // v=0; n1=1 (len 1), n2=2 (len 4)
    bool hadNeighbors;
    Vec3 actual = TopologyPenTool.inverseEdgeLenRelax(readPos, 0, [1u, 2u], hadNeighbors);
    assert(hadNeighbors, "a 2-neighbor set must report usable relax neighbors");

    float w1 = 1.0f / (readPos[0] - readPos[1]).length;
    float w2 = 1.0f / (readPos[0] - readPos[2]).length;
    Vec3 expected = (readPos[1] * w1 + readPos[2] * w2) * (1.0f / (w1 + w2));

    assert((actual - expected).length < 1e-5f,
        format("expected the inverse-edge-length midpoint %s; got %s", expected, actual));
}

unittest { // inverseEdgeLenRelax — a 1-neighbor set relaxes FULLY onto that
           // single neighbor (kStrength=1 -> weightedSum/weightSum reduces to
           // the one neighbor's own position exactly) — a pure property of
           // the shared weighting law over WHATEVER list it's handed;
           // F1's "held fixed" policy for a real open-loop end lives at the
           // `applySmoothLoopPasses` call site's `!= 2` guard below, never
           // inside this topology-agnostic kernel.
    Vec3[] readPos = [Vec3(0, 0, 0), Vec3(5, 2, -3)];
    bool hadNeighbors;
    Vec3 actual = TopologyPenTool.inverseEdgeLenRelax(readPos, 0, [1u], hadNeighbors);
    assert(hadNeighbors, "a 1-neighbor set must report usable relax neighbors");
    assert((actual - readPos[1]).length < 1e-5f,
        "a single-neighbor relax must land exactly on that neighbor");
}

unittest { // inverseEdgeLenRelax — a 0-neighbor set is a true no-op:
           // `readPos[v]` byte-unchanged, `hadNeighbors` stays false.
    Vec3[] readPos = [Vec3(1, 2, 3)];
    bool hadNeighbors;
    const(uint)[] noNbrs;
    Vec3 actual = TopologyPenTool.inverseEdgeLenRelax(readPos, 0, noNbrs, hadNeighbors);
    assert(!hadNeighbors, "an empty neighbor set must report NO usable neighbors");
    assert(actual == readPos[0], "an empty neighbor set must be a byte-identical no-op");
}

unittest { // loopNeighborsOf — an interior loop vertex gets exactly its 2
           // loop-neighbors; an open-chain END gets exactly 1
           // (doc/topopen_p12_smoothloop_plan.md Phase 1 — mirrors
           // `uniqueRingVerts`'s own REV1 FIX-1 grid rig: `makeGridPlane(2)`,
           // a 3x3 vertex grid, `index(i,j) = i*3+j`).
    import mesh : makeGridPlane;
    import std.algorithm : sort;

    Mesh m = makeGridPlane(2);   // 3x3 verts (0..8), 4 quads, 12 edges

    uint seedRow = m.edgeIndex(3, 4);
    assert(seedRow != uint.max, "setup: middle-row edge 3-4 must exist");
    auto rowNbrs = TopologyPenTool.loopNeighborsOf(&m, seedRow);
    assert(rowNbrs[3] == [4u], "open-chain END (3) must have exactly 1 loop-neighbor");
    assert(rowNbrs[5] == [4u], "open-chain END (5) must have exactly 1 loop-neighbor");
    auto n4 = rowNbrs[4].dup;
    sort(n4);
    assert(n4 == [3u, 5u], "interior loop vertex (4) must have exactly its 2 loop-neighbors");

    uint seedBoundary = m.edgeIndex(0, 1);
    assert(seedBoundary != uint.max, "setup: top-row boundary edge 0-1 must exist");
    auto boundaryNbrs = TopologyPenTool.loopNeighborsOf(&m, seedBoundary);
    foreach (vi; [0u, 1u, 2u, 3u, 5u, 6u, 7u, 8u])
        assert(boundaryNbrs[vi].length == 2,
            "every vertex of a CLOSED perimeter loop must have exactly 2 loop-neighbors");
}

unittest { // applySmoothLoopPasses — interior relax + nearest-foot re-snap,
           // non-loop verts UNCHANGED, F1 open-chain ENDPOINTS byte-unchanged,
           // δ=0, undo restores exactly (doc/topopen_p12_smoothloop_plan.md
           // §Testing Strategy + ⚠️ F1 RESOLVED's own added test). Uses the
           // SAME interior seed (edge 3-4) as `uniqueRingVerts`'s/
           // `loopNeighborsOf`'s own grid rig above — the gathered chain
           // [3,4,5] is EXACTLY the owner-observed "3x3 side edge" shape: 3
           // and 5 are the open-chain ENDS (1 loop-neighbor each), 4 is the
           // sole interior vertex (2 loop-neighbors). Vertex 4 is perturbed
           // off the flat grid's own colinear midpoint (else the relax would
           // be a no-op on this perfectly uniform grid) so the test can
           // discriminate "actually relaxed" from "left alone".
    import view : View;
    import editmode : EditMode;
    import mesh : makeGridPlane;
    import snap : setBackgroundSnapSources;
    import std.math : abs;
    import std.format : format;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_               = history;
    t.smoothLoopEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                         "mesh.topoPen_smoothloop", "Topology Smooth Loop",
                                                         MeshEditScope.Position);

    Mesh m = makeGridPlane(2);
    t.meshSrc_ = () => &m;

    // Perturb vertex 4 off the flat grid's own colinear midpoint between 3
    // and 5 — on the UN-perturbed grid, 3/4/5 are exactly colinear and
    // evenly spaced, so the inverse-edge-length mean IS vertex 4's own
    // current position (a coincidental no-op unrelated to this gesture's
    // own no-op guard).
    m.vertices[4] = Vec3(0.3f, 2.0f, 0.0f);

    // A large flat background plane well below the perturbed grid.
    enum float planeY = -0.5f;
    auto bg = new Mesh();
    bg.vertices = [Vec3(-20, planeY, -20), Vec3(20, planeY, -20),
                   Vec3(20, planeY, 20),   Vec3(-20, planeY, 20)];
    bg.faces    = [[0u, 1u, 2u, 3u]];
    const(Mesh)*[] srcs = [cast(const(Mesh)*) bg];
    import math : ModelSpace;
    setBackgroundSnapSources(srcs, new ModelSpace[](srcs.length));
    scope(exit) setBackgroundSnapSources(null, null);

    uint seed = m.edgeIndex(3, 4);
    assert(seed != uint.max);
    auto verts = TopologyPenTool.uniqueRingVerts(&m, seed);
    assert(verts == [3u, 4u, 5u]);

    t.smoothLoopSeed_  = cast(int)seed;
    t.smoothLoopVerts_ = verts;

    Vec3 orig3 = m.vertices[3], orig4 = m.vertices[4], orig5 = m.vertices[5];
    // Independently-computed inverse-edge-length target for vertex 4, off
    // the SAME pre-pass positions `applySmoothLoopPasses` will read.
    float w3 = 1.0f / (orig4 - orig3).length;
    float w5 = 1.0f / (orig4 - orig5).length;
    Vec3 expectedMean = (orig3 * w3 + orig5 * w5) * (1.0f / (w3 + w5));

    Vec3[] beforeAll = m.vertices.dup;
    size_t vBefore = m.vertices.length, eBefore = m.edges.length, fBefore = m.faces.length;

    t.applySmoothLoopPasses(1);

    // (1) Interior vertex 4 relaxed to the independently-computed
    // inverse-edge-length midpoint (X/Z) AND lies ON the background plane
    // (perp distance to the surface ~0 — nearest-FOOT re-snap, not a
    // camera-ray one).
    assert(abs(m.vertices[4].x - expectedMean.x) < 1e-4f
        && abs(m.vertices[4].z - expectedMean.z) < 1e-4f,
        format("interior vertex 4 must relax to the inverse-edge-length midpoint's X/Z; "
             ~ "expected (%f,_,%f), got %s", expectedMean.x, expectedMean.z, m.vertices[4]));
    assert(abs(m.vertices[4].y - planeY) < 1e-3f,
        format("interior vertex 4 must land ON the background plane (y~=%f); got y=%f",
               planeY, m.vertices[4].y));

    // (2) F1 (⚠️ F1 RESOLVED, "концы стоят на месте"): BOTH open-chain
    // endpoints (3, 5) are byte-unchanged — held fixed, no relax, no re-snap.
    assert(m.vertices[3] == orig3, "F1: open-chain endpoint 3 must be byte-unchanged");
    assert(m.vertices[5] == orig5, "F1: open-chain endpoint 5 must be byte-unchanged");

    // (3) Non-loop vertices (everything except 3,4,5) are byte-unchanged —
    // the "only loop vertices move" contract, dedicated assertion over
    // every index NOT in the gathered moving-set.
    foreach (vi; 0 .. m.vertices.length) {
        bool inLoop = (vi == 3 || vi == 4 || vi == 5);
        if (inLoop) continue;
        assert(m.vertices[vi] == beforeAll[vi],
            format("non-loop vertex %d must be byte-unchanged", vi));
    }

    // (4) δ=0: topology counts unchanged.
    assert(m.vertices.length == vBefore && m.edges.length == eBefore && m.faces.length == fBefore,
        "Smooth+Loop must never change topology (δ=0)");
    assert(history.canUndo(), "a real Smooth+Loop commit must record one undo entry");

    // (5) Undo restores exactly.
    history.undo();
    assert((m.vertices[3] - orig3).length < 1e-6f
        && (m.vertices[4] - orig4).length < 1e-6f
        && (m.vertices[5] - orig5).length < 1e-6f,
        "undo must restore every loop vertex's exact pre-relax position");
}

unittest { // applySmoothLoopPasses — a gesture that nets to ZERO movement
           // (the flat, un-perturbed grid: 3/4/5 are exactly colinear and
           // evenly spaced, so vertex 4's inverse-edge-length mean IS its own
           // current position, and no background source exists to re-snap
           // anything) is the ROUTINE no-op case — byte-identical mesh, NO
           // undo entry (mirrors `applySmoothPasses`'s own T7 no-op test).
    import view : View;
    import editmode : EditMode;
    import mesh : makeGridPlane;
    import snap : setBackgroundSnapSources;

    setBackgroundSnapSources(null, null);   // test-isolation, not a production call site

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_               = history;
    t.smoothLoopEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                         "mesh.topoPen_smoothloop", "Topology Smooth Loop",
                                                         MeshEditScope.Position);

    Mesh m = makeGridPlane(2);
    t.meshSrc_ = () => &m;

    uint seed = m.edgeIndex(3, 4);
    t.smoothLoopSeed_  = cast(int)seed;
    t.smoothLoopVerts_ = TopologyPenTool.uniqueRingVerts(&m, seed);

    auto before = MeshSnapshot.capture(m);
    t.applySmoothLoopPasses(1);
    auto after = MeshSnapshot.capture(m);

    assert(after.vertices == before.vertices,
        "a flat/uniform grid with no background must be a byte-identical no-op");
    assert(!history.canUndo(), "a no-op Smooth+Loop gesture must record NO undo entry");
}

// ---------------------------------------------------------------------------
// onSmoothLoopRmbDown — ARM + CONSUME on a valid seed edge; MISS does not
// consume/arm (doc/topopen_p12_smoothloop_plan.md "RMB-dispatch resolution":
// a miss must fall through to Shift+Ctrl+RMB-lasso unchanged).
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import mesh : makeGridPlane;
    import toolpipe.packets : SubjectPacket;
    import std.format : format;

    auto t    = new TopologyPenTool();
    auto view = new View(0, 0, 100, 100);
    Mesh m = makeGridPlane(2);
    t.meshSrc_ = () => &m;

    Viewport vp = view.viewport();
    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    ImVec2 p3, p4;
    assert(TopologyPenTool.projectWorldPt(m.vertices[3], vp, p3));
    assert(TopologyPenTool.projectWorldPt(m.vertices[4], vp, p4));
    int mx = cast(int)((p3.x + p4.x) * 0.5f), my = cast(int)((p3.y + p4.y) * 0.5f);

    SDL_MouseButtonEvent eHit;
    eHit.button = SDL_BUTTON_RIGHT;
    eHit.x = mx; eHit.y = my;
    bool consumed = t.onSmoothLoopRmbDown(eHit, vts);
    assert(consumed, "a press on a valid edge midpoint must arm and consume");
    assert(t.smoothLoopArmed_, "must arm the Smooth+Loop gesture");
    assert(t.smoothLoopVerts_ == [3u, 4u, 5u],
        format("armed moving-set must be the in-line row chain; got %s", t.smoothLoopVerts_));

    t.smoothLoopArmed_ = false;   // reset for the miss probe below
    SDL_MouseButtonEvent eMiss;
    eMiss.button = SDL_BUTTON_RIGHT;
    eMiss.x = -5000; eMiss.y = -5000;   // far from every edge
    bool missConsumed = t.onSmoothLoopRmbDown(eMiss, vts);
    assert(!missConsumed, "a press far from every edge must NOT consume");
    assert(!t.smoothLoopArmed_, "a miss must not arm the gesture");
}

// ---------------------------------------------------------------------------
// onMouseButtonUp — RIGHT-branch, Smooth+Loop is NOT `kMinDragPx`-gated (a
// stationary click still applies its one pass, mirroring the whole-mesh
// Smooth gesture's own Risk-5 discipline, P8) — driven through the extracted
// `smoothLoopUp` release-side helper directly (arming state set up
// directly, mirroring P10/P11's own click-vs-drag tests) so the commit path
// itself is under test. Phase-2 input-dispatch migration
// (doc/topopen_input_dispatch_phase2_plan.md, Testing Category C): calls
// `smoothLoopUp` directly rather than `onMouseButtonUp` — see the Slide
// MIN-DRAG test's own doc comment for why.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import mesh : makeGridPlane;
    import snap : setBackgroundSnapSources;

    setBackgroundSnapSources(null, null);   // test-isolation: force the deterministic no-bg no-op path

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_               = history;
    t.smoothLoopEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                         "mesh.topoPen_smoothloop", "Topology Smooth Loop",
                                                         MeshEditScope.Position);

    Mesh m = makeGridPlane(2);
    t.meshSrc_ = () => &m;

    uint seed = m.edgeIndex(3, 4);
    t.smoothLoopSeed_    = cast(int)seed;
    t.smoothLoopArmed_   = true;
    t.smoothLoopStartX_  = 50;
    t.smoothLoopStartY_  = 50;
    t.smoothLoopCurX_    = 50;
    t.smoothLoopCurY_    = 50;
    t.smoothLoopDragPx_  = 0.0f;
    t.smoothLoopVerts_   = TopologyPenTool.uniqueRingVerts(&m, seed);

    auto before = MeshSnapshot.capture(m);
    SDL_MouseButtonEvent e;
    e.button = SDL_BUTTON_RIGHT;
    e.x = 50; e.y = 50;   // release exactly at the press pixel -- a stationary click
    VectorStack vts;
    bool consumed = t.smoothLoopUp(e, vts);
    auto after = MeshSnapshot.capture(m);

    assert(consumed, "a stationary-click release must still consume the event");
    assert(!t.smoothLoopArmed_, "release must disarm Smooth+Loop regardless of outcome");
    // The flat/uniform grid + no background is a byte-identical no-op (the
    // SAME rig as `applySmoothLoopPasses`'s own no-op unittest above) -- this
    // additionally proves the RIGHT-branch dispatch applies exactly ONE pass
    // for a click, with no `kMinDragPx` gate suppressing it.
    assert(after.vertices == before.vertices,
        "a stationary click on a no-op rig must leave the mesh byte-identical");
    assert(!history.canUndo(), "a no-op click must record NO undo entry");
}

// ---------------------------------------------------------------------------
// resyncSession — clears a stray Smooth+Loop arm
// (doc/topopen_p12_smoothloop_plan.md "Undo factory"): an external history
// navigation mid-drag must not leave a dangling seed/moving-set for the
// eventual (now stale) release to commit against.
// ---------------------------------------------------------------------------
unittest {
    auto t = new TopologyPenTool();
    t.smoothLoopArmed_   = true;
    t.smoothLoopSeed_    = 3;
    t.smoothLoopVerts_   = [3u, 4u, 5u];
    t.smoothLoopDragPx_  = 42.0f;

    t.resyncSession();

    assert(!t.smoothLoopArmed_, "resyncSession must clear the armed Smooth+Loop gesture");
    assert(t.smoothLoopSeed_ == -1, "resyncSession must reset the seed index");
    assert(t.smoothLoopVerts_.length == 0, "resyncSession must clear the moving-set");
    assert(t.smoothLoopDragPx_ == 0.0f, "resyncSession must reset the drag-distance accumulator");
}

// ---------------------------------------------------------------------------
// toolStateJson — Smooth+Loop fields (doc/topopen_p12_smoothloop_plan.md
// Phase 4): reports the armed seed + moving-set size + derived pass count,
// for Tier-C tests to assert without driving a full release.
// ---------------------------------------------------------------------------
unittest {
    import std.json : JSONType;

    auto t = new TopologyPenTool();

    auto s0 = t.toolStateJson();
    assert(s0["smoothLoopArmed"].type == JSONType.false_, "must start with no armed Smooth+Loop");
    assert(cast(int)s0["smoothLoopSeed"].integer == -1, "must start with seed=-1");
    assert(cast(int)s0["smoothLoopVertCount"].integer == 0, "must start with an empty moving-set");
    assert(cast(int)s0["smoothLoopPassCount"].integer == 1, "a fresh (unarmed) tool reports pass count 1");

    t.smoothLoopArmed_  = true;
    t.smoothLoopSeed_   = 7;
    t.smoothLoopVerts_  = [1u, 2u, 3u, 4u];
    t.smoothLoopDragPx_ = 45.0f;   // 1 + floor(45/20) = 3 passes

    auto s1 = t.toolStateJson();
    assert(s1["smoothLoopArmed"].type == JSONType.true_, "must report the armed state");
    assert(cast(int)s1["smoothLoopSeed"].integer == 7, "must report the picked seed edge");
    assert(cast(int)s1["smoothLoopVertCount"].integer == 4, "must report the gathered moving-set size");
    assert(cast(int)s1["smoothLoopPassCount"].integer == 3,
        "must report the SAME pass-count derivation onMouseButtonUp will apply");
}

// ---------------------------------------------------------------------------
// onMouseButtonDown / onMouseMotion / onMouseButtonUp — MANDATORY DISPATCH
// (P12, doc/topopen_p12_smoothloop_plan.md): drives the REAL Shift+Ctrl+RMB
// gesture end-to-end — dispatch (`onMouseButtonDown` -> `dispatchInput` ->
// `PenGesture.SmoothLoop` -> `onSmoothLoopRmbDown`), a motion event (drag-distance
// accumulation), and the RIGHT-button release branch (->
// `applySmoothLoopPasses`) — against a REAL background mesh
// (`setBackgroundSnapSources`, CPU-only BVH raycast, no GL context needed),
// so this is a genuine end-to-end proof (not just the mutation, as the
// Tier-B `applySmoothLoopPasses` cases above already cover, nor just the
// dispatch wiring, as `onSmoothLoopRmbDown`'s own test above covers) — all
// still pure-`dub test`. Reuses the SAME perturbed-vertex-4 rig as the
// Tier-B relax test above, so the real dispatch path is proven to reach the
// identical relax+re-snap outcome.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import mesh : makeGridPlane;
    import toolpipe.packets : SubjectPacket;
    import snap : setBackgroundSnapSources;
    import std.math : abs;
    import std.format : format;

    loadSDL();
    SDL_SetModState(cast(SDL_Keymod)(KMOD_SHIFT | KMOD_CTRL));
    scope(exit) SDL_SetModState(cast(SDL_Keymod)0);   // don't leak into later dub-test unittests

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 200, 200);
    auto history = new CommandHistory();
    t.history_               = history;
    t.smoothLoopEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                         "mesh.topoPen_smoothloop", "Topology Smooth Loop",
                                                         MeshEditScope.Position);

    Mesh m = makeGridPlane(2);
    t.meshSrc_ = () => &m;
    m.vertices[4] = Vec3(0.3f, 2.0f, 0.0f);   // off the flat grid's own colinear midpoint

    Viewport vp = view.viewport();

    enum float planeY = -0.5f;
    auto bg = new Mesh();
    bg.vertices = [Vec3(-20, planeY, -20), Vec3(20, planeY, -20),
                   Vec3(20, planeY, 20),   Vec3(-20, planeY, 20)];
    bg.faces    = [[0u, 1u, 2u, 3u]];
    const(Mesh)*[] srcs = [cast(const(Mesh)*) bg];
    import math : ModelSpace;
    setBackgroundSnapSources(srcs, new ModelSpace[](srcs.length));
    scope(exit) setBackgroundSnapSources(null, null);

    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    ImVec2 p3, p4;
    assert(TopologyPenTool.projectWorldPt(m.vertices[3], vp, p3));
    assert(TopologyPenTool.projectWorldPt(m.vertices[4], vp, p4));
    int mx = cast(int)((p3.x + p4.x) * 0.5f), my = cast(int)((p3.y + p4.y) * 0.5f);

    Vec3 orig3 = m.vertices[3], orig5 = m.vertices[5];

    SDL_MouseButtonEvent eDown;
    eDown.button = SDL_BUTTON_RIGHT;
    eDown.x = mx; eDown.y = my;
    bool downConsumed = t.onMouseButtonDown(eDown, vts);
    assert(downConsumed, "Shift+Ctrl+RMB-down on the seed edge must be consumed via the real dispatch");
    assert(t.smoothLoopArmed_, "the real dispatch must have armed Smooth+Loop");
    assert(t.smoothLoopVerts_ == [3u, 4u, 5u], "the real dispatch must have gathered the row chain");

    SDL_MouseMotionEvent eMove;
    eMove.x = mx + 8; eMove.y = my - 5;
    bool moveConsumed = t.onMouseMotion(eMove, vts);
    assert(moveConsumed, "motion while armed must be consumed");
    assert(t.smoothLoopDragPx_ > 0.0f, "motion must accumulate drag distance");

    size_t vBefore = m.vertices.length, eBefore = m.edges.length, fBefore = m.faces.length;

    SDL_MouseButtonEvent eUp;
    eUp.button = SDL_BUTTON_RIGHT;
    eUp.x = mx + 8; eUp.y = my - 5;
    bool upConsumed = t.onMouseButtonUp(eUp, vts);
    assert(upConsumed, "RMB-up must be consumed");
    assert(!t.smoothLoopArmed_, "release must disarm Smooth+Loop regardless of outcome");

    assert(m.vertices.length == vBefore && m.edges.length == eBefore && m.faces.length == fBefore,
        "Smooth+Loop must never change topology (δ=0)");
    assert(history.canUndo(), "the real dispatch path must record one undo entry");

    // F1: both open-chain endpoints stay exactly put; only the interior
    // vertex (4) moved and landed on the background plane.
    assert(m.vertices[3] == orig3, "F1: endpoint 3 must be byte-unchanged via the real dispatch");
    assert(m.vertices[5] == orig5, "F1: endpoint 5 must be byte-unchanged via the real dispatch");
    assert(abs(m.vertices[4].y - planeY) < 0.05f,
        format("interior vertex 4 must land ON the background plane (y~=%f); got y=%f",
               planeY, m.vertices[4].y));

    SDL_SetModState(cast(SDL_Keymod)0);   // leave the shared SDL modifier global clean
}

// ---------------------------------------------------------------------------
// commitSplit — Split Tier-B #1 (the whole of Split): the vertex<->vertex
// chord split — Δv=0, no vertex is ever inserted on this path.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_          = history;
    t.splitEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                    "mesh.topoPen_split", "Topology Split",
                                                    MeshEditScope.Geometry);

    Mesh m;
    t.meshSrc_ = () => &m;
    m.addVertex(Vec3(0, 0, 0));
    m.addVertex(Vec3(1, 0, 0));
    m.addVertex(Vec3(1, 1, 0));
    m.addVertex(Vec3(0, 1, 0));
    m.addFace([0u, 1u, 2u, 3u]);
    m.buildLoops();

    t.commitSplit(0, 2);

    assert(m.vertices.length == 4, "vertex<->vertex split: Δv=0 — Split never creates a vertex");
    assert(m.faces.length    == 2, "vertex<->vertex split: still 2 faces");
    assert(history.canUndo());
}

// ---------------------------------------------------------------------------
// splitUp — Split Tier-B #2 (no-op): release on empty space (no vertex
// within the drag-snap acceptance radius) is a clean no-op — the release must not
// fabricate a target out of nothing.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import toolpipe.packets : SubjectPacket;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 200, 200);
    auto history = new CommandHistory();
    t.history_          = history;
    t.splitEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                    "mesh.topoPen_split", "Topology Split",
                                                    MeshEditScope.Geometry);

    Mesh m;
    t.meshSrc_ = () => &m;
    m.addVertex(Vec3(0, 0, 0));
    m.addVertex(Vec3(0.2f, 0, 0));
    m.addVertex(Vec3(0.2f, 0.2f, 0));
    m.addVertex(Vec3(0, 0.2f, 0));
    m.addFace([0u, 1u, 2u, 3u]);
    m.buildLoops();

    Viewport vp = view.viewport();
    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    auto before = MeshSnapshot.capture(m);

    t.splitArmed_      = true;
    t.splitSourceVert_ = 0;
    // Hand-armed like the two lines above, because this case enters at
    // `splitUp` and never runs the press that would have captured it. Task
    // 0523: without it the master gate would answer for the release and this
    // would be a no-op case that proves nothing about EMPTY SPACE.
    t.dragSnap_        = *penTestSnapOn();
    SDL_MouseButtonEvent eUp;
    eUp.button = SDL_BUTTON_MIDDLE;
    eUp.x = 5; eUp.y = 5;   // far corner -- nothing projects anywhere near here
    bool consumed = t.splitUp(eUp, vts);
    assert(consumed, "splitUp must still consume the release even on a no-op");

    auto after = MeshSnapshot.capture(m);
    assert(after.vertices == before.vertices && after.edges == before.edges
        && after.faces == before.faces,
        "empty-space release: byte-identical no-op");
    assert(!history.canUndo(), "empty-space release: must record no undo entry");
    assert(!t.splitArmed_, "release must disarm Split regardless of outcome");
}

// ---------------------------------------------------------------------------
// params() / toolStateJson — Add Loop "at the Middle" option schema
// (doc/tasks/work/0480-topopen-addloop-middle.md): the sticky `middle` Param
// round-trips through both the schema (for the `tool.attr`/form binding) and
// the introspection JSON (for HTTP tests), defaulting OFF, and survives
// `resyncSession()` (a mode toggle, not per-gesture arm state — matches the
// `tool_activate_sticky_clobber` precedent).
// ---------------------------------------------------------------------------
unittest {
    import std.json : JSONType;

    auto t = new TopologyPenTool();

    auto ps = t.params();
    assert(ps.length == 12, "mesh.topoPen must expose the Add Loop `middle` option, the Mode "
                          ~ "dropdown, the Edge Loop / Edge Slide flags (task 0483), the Smooth "
                          ~ "strength, the two display toggles (task 0499), the Inner Snap "
                          ~ "flag (task 0496), the Keep Vertices flag (task 0494), the two "
                          ~ "Fill attributes (task 0488) and the Backface flag (task 0538) — "
                          ~ "every later Param is APPENDED, never a full-replace");
    assert(ps[$ - 1].name == "backFace",
        "the Backface flag must be APPENDED LAST (task 0538)");
    assert(ps[$ - 3].name == "range" && ps[$ - 2].name == "quadOnly",
        "the two Fill attributes must keep their positions, in that order");
    assert(ps[$ - 3].hints.hasMinF && ps[$ - 3].hints.minF == 0.0f && !ps[$ - 3].hints.hasMaxF,
        "`range`'s bounds are the MEASURED ones: min 0.0 and NO upper bound — not a "
      ~ "sane-looking pair invented at the call site");
    assert(ps[$ - 2].kind == Param.Kind.Bool && ps[$ - 2].default_.b == true,
        "`quadOnly` is the measured boolean count gate, default ON");
    assert(ps[0].name == "middle");
    assert(ps[0].kind == Param.Kind.Bool);
    assert(ps[0].default_.b == false, "`middle` must default OFF — the shipped click-derived "
                                     ~ "Add Loop ratio stays the default behaviour");
    assert(ps[0].bptr is &t.addLoopMiddle_, "the Param must bind directly to addLoopMiddle_");

    auto s0 = t.toolStateJson();
    assert(s0["addLoopMiddle"].type == JSONType.false_, "must start OFF");
    assert("splitAtMiddle" !in s0,
        "the option is no longer attached to Split — the old key must be gone, not aliased");
    // Task 0538: the flag has to be READABLE from outside, not merely settable.
    // Without the readback an automated run cannot tell "I set Backface and the
    // candidate was still refused" from "my set never landed" — the exact
    // failure mode that has manufactured false divergences before.
    assert(s0["backFace"].type == JSONType.false_,
        "/api/tool/state must publish `backFace`, starting at its measured default OFF");

    t.addLoopMiddle_ = true;
    t.backFace_      = true;
    auto s1 = t.toolStateJson();
    assert(s1["addLoopMiddle"].type == JSONType.true_, "must report a live toggle");
    assert(s1["backFace"].type == JSONType.true_,
        "and `backFace` must report a live toggle too, not a snapshot of the default");
    t.backFace_ = false;

    t.resyncSession();
    assert(t.addLoopMiddle_,
        "addLoopMiddle_ must survive resyncSession() (external history navigation) — it is a "
      ~ "sticky mode toggle, not per-gesture arm state");
}

// ---------------------------------------------------------------------------
// addLoopFrac — the Add Loop insert-fraction LAW
// (doc/tasks/work/0480-topopen-addloop-middle.md):
// `frac = middle ? 0.5 : clamp(cursorRatio, 0, 1)`. Pins both branches
// directly, including the fact that `middle` ignores the cursor ENTIRELY
// (not "clamps it toward 0.5"), and that `addLoopRatio`/`addLoopFrac` in the
// introspection JSON diverge exactly when the option is on.
// ---------------------------------------------------------------------------
unittest {
    import std.math : abs, isNaN;

    auto t = new TopologyPenTool();

    // --- option OFF: the click-derived ratio passes through, clamped ---
    assert(abs(t.addLoopFrac(0.3f)  - 0.3f) < 1e-6f, "OFF: the cursor ratio passes through");
    assert(abs(t.addLoopFrac(0.75f) - 0.75f) < 1e-6f);
    assert(abs(t.addLoopFrac(-2.0f) - 0.0f) < 1e-6f, "OFF: below-range clamps to 0");
    assert(abs(t.addLoopFrac(9.0f)  - 1.0f) < 1e-6f, "OFF: above-range clamps to 1");
    assert(abs(t.addLoopFrac(float.nan) - 0.0f) < 1e-6f,
        "OFF: a non-finite ratio must resolve to the rejected 0, never propagate — "
      ~ "commitAddLoop's open-interval guard then no-ops it");

    // --- option ON: a flat 0.5, whatever the cursor says ---
    t.addLoopMiddle_ = true;
    foreach (float r; [0.0f, 0.05f, 0.3f, 0.5f, 0.95f, 1.0f, -3.0f, 7.0f]) {
        assert(abs(t.addLoopFrac(r) - 0.5f) < 1e-6f,
            "ON: `middle` bypasses the cursor entirely — always exactly 0.5");
    }
    assert(!isNaN(t.addLoopFrac(float.nan)) && abs(t.addLoopFrac(float.nan) - 0.5f) < 1e-6f,
        "ON: even a non-finite cursor ratio is bypassed, not propagated");

    // --- the introspection JSON reports BOTH the raw ratio and the law's
    //     output, so a Tier-C test can see the override without a release ---
    t.addLoopRatio_ = 0.8f;
    auto s = t.toolStateJson();
    assert(abs(s["addLoopRatio"].get!double - 0.8) < 1e-6,
        "addLoopRatio must stay the RAW cursor ratio");
    assert(abs(s["addLoopFrac"].get!double - 0.5) < 1e-6,
        "addLoopFrac must report what a release would actually commit");
}

// ---------------------------------------------------------------------------
// params() — Mode dropdown schema (task 0477 continuation + task 0483): the
// `mode` IntEnum Param round-trips through the schema (for the
// `tool.attr`/form binding), carries the reference's OWN eight values in the
// reference's own order under the reference's own wire tags, defaults to the
// live-measured `move`, and survives `resyncSession()` (a sticky mode toggle,
// not per-gesture arm state — matches `addLoopMiddle_`'s own precedent,
// pinned in the schema block above).
//
// The wire-tag list is pinned member-by-member ON PURPOSE: these tags are the
// external contract (`tool.attr mesh.topoPen mode <tag>`, the `/api/tool/state`
// readback, every reference-comparison harness case), so a rename or a
// reordering has to be a deliberate edit here, not a silent side effect.
// ---------------------------------------------------------------------------
unittest {
    auto t = new TopologyPenTool();

    auto ps = t.params();
    assert(ps[1].name == "mode");
    assert(ps[1].kind == Param.Kind.IntEnum);
    assert(ps[1].default_.i == cast(int)PenMode.Move, "mode must default to Move");
    assert(ps[1].iePtr is cast(int*)&t.penMode_, "the Param must bind directly to penMode_");
    assert(ps[1].intEnumValues.length == 8, "the reference's mode enum has exactly 8 values");

    static immutable string[8] wantTags =
        ["move", "duplicate", "remove", "split", "addLoop", "point", "fill", "smooth"];
    static immutable string[8] wantLabels =
        ["Move", "Duplicate", "Remove", "Split", "Add Loop", "Point", "Fill", "Smoothing"];
    foreach (i, want; wantTags) {
        assert(ps[1].intEnumValues[i].wireTag == want,
            "mode entry " ~ want ~ " must keep its reference wire tag and position");
        assert(ps[1].intEnumValues[i].userLabel == wantLabels[i],
            "mode entry " ~ want ~ " must keep its reference label");
        assert(ps[1].intEnumValues[i].value == cast(int)i,
            "the table's values must be the enum's own ordinals, in order");
    }

    assert(t.penMode_ == PenMode.Move, "must start in Move mode");

    t.penMode_ = PenMode.Fill;
    t.resyncSession();
    assert(t.penMode_ == PenMode.Fill,
        "penMode_ must survive resyncSession() (external history navigation) — it is a sticky "
      ~ "mode toggle, not per-gesture arm state");
}

// ---------------------------------------------------------------------------
// params() — Edge Loop / Edge Slide schema (task 0483): the reference's own
// two dropdown-adjacent checkboxes, bound to the fields the router reads,
// both defaulting OFF (live-measured), both sticky across `resyncSession()`
// for the same reason `penMode_` is.
// ---------------------------------------------------------------------------
unittest {
    auto t = new TopologyPenTool();

    auto ps = t.params();
    assert(ps[2].name == "loop"  && ps[2].kind == Param.Kind.Bool);
    assert(ps[3].name == "slide" && ps[3].kind == Param.Kind.Bool);
    assert(ps[2].bptr is &t.edgeLoop_,  "loop must bind directly to edgeLoop_");
    assert(ps[3].bptr is &t.edgeSlide_, "slide must bind directly to edgeSlide_");
    assert(!ps[2].default_.b && !ps[3].default_.b, "both flags default OFF");
    assert(!t.edgeLoop_ && !t.edgeSlide_, "a fresh tool must start with both flags OFF");

    // Inner Snap (task 0496) — the third sticky flag, APPENDED last, default
    // OFF (measured). It selects the pen snap target's candidate set.
    // Index 7, not 5: task 0499's two display toggles were appended first, and the
    // module's rule is APPEND-never-replace — so a merge shifts the index, never the order.
    assert(ps[7].name == "innerSnap" && ps[7].kind == Param.Kind.Bool);
    assert(ps[7].bptr is &t.innerSnap_, "innerSnap must bind directly to innerSnap_");
    assert(!ps[7].default_.b && !t.innerSnap_,
        "innerSnap must default OFF — border-only snap candidates is the measured default");

    // Keep Vertices (task 0494) — the fourth sticky flag, APPENDED last,
    // default OFF (measured in both directions). Index 8 for the same reason
    // innerSnap is 7: the module's rule is APPEND-never-replace, so a merge
    // shifts the index and never the order.
    //
    // The default is the whole point of this row, not a formality: with it OFF
    // a Remove press on an interior edge loop DELETES the vertices whose whole
    // polygon fan the dissolve ate. Flipping this literal to `true` would
    // silently restore the pre-0494 behaviour tool-wide.
    assert(ps[8].name == "keepVertex" && ps[8].kind == Param.Kind.Bool);
    assert(ps[8].bptr is &t.keepVertex_, "keepVertex must bind directly to keepVertex_");
    assert(!ps[8].default_.b && !t.keepVertex_,
        "keepVertex must default OFF — purging the consumed vertices is the measured default");

    // Backface (task 0538) — the ORIENTATION half of the admission policy
    // `innerSnap` is the topology half of, APPENDED last, default OFF
    // (measured). Index 11 for the same reason innerSnap is 7 and keepVertex
    // is 8: APPEND-never-replace, so a merge shifts the index, never the order.
    //
    // The default is the whole point of this row too: with it OFF the pen's
    // snap target refuses a candidate whose own normal faces away from the
    // viewer. Flipping this literal to `true` would silently restore the
    // pre-0538 behaviour, which was the ON branch tool-wide.
    assert(ps[11].name == "backFace" && ps[11].kind == Param.Kind.Bool);
    assert(ps[11].bptr is &t.backFace_, "backFace must bind directly to backFace_");
    assert(!ps[11].default_.b && !t.backFace_,
        "backFace must default OFF — refusing back-facing snap candidates is the measured "
      ~ "default, and it is the branch we did NOT ship before");

    // Every attr the form file names has to exist here, and every attr here has
    // to be reachable by its wire name — `validateForms` enforces that at boot,
    // so a typo in either direction is a startup failure and not a silent
    // no-op. Pinned by NAME, so a rename is a deliberate edit in both places.
    static immutable string[12] wantNames = [
        "middle", "mode", "loop", "slide", "smoothStrength", "showVertex",
        "showEdge", "innerSnap", "keepVertex", "range", "quadOnly", "backFace",
    ];
    assert(ps.length == wantNames.length,
        "the published attribute list changed size — add the row to `wantNames` deliberately");
    foreach (i, want; wantNames)
        assert(ps[i].name == want,
            "published attr " ~ want ~ " must keep its wire name and its position");

    t.edgeLoop_ = t.edgeSlide_ = t.innerSnap_ = t.keepVertex_ = t.backFace_ = true;
    t.resyncSession();
    assert(t.edgeLoop_ && t.edgeSlide_ && t.innerSnap_ && t.keepVertex_ && t.backFace_,
        "the flags must survive resyncSession() — sticky options, not gesture state");
}

// ---------------------------------------------------------------------------
// The Mode router's full table (task 0483) — every (mode, Edge Loop) pair
// dispatches an unmodified LMB press to the gesture the reference pairs it
// with. Asserted through `gestureOn_`, the router's own recorded decision,
// so a row is pinned by WHICH gesture it chose and not by whether that
// gesture happened to find a seed under the probe pixel: a seed miss is the
// delegated handler's business (each has its own tests), a misrouted mode is
// this table's.
//
// The press pixel is an edge midpoint on a grid plane — geometry, so the
// Move family takes its on-geometry branch — and the same pixel is used for
// every row, which is what makes the rows comparable.
// ---------------------------------------------------------------------------
unittest {
    import mesh : makeGridPlane;
    import toolpipe.packets : SubjectPacket;

    Mesh m = makeGridPlane(3);
    auto vp = makeGridPlaneTestViewport();

    ImVec2 pa, pb;
    assert(TopologyPenTool.projectWorldPt(m.vertices[m.edges[0][0]], vp, pa), "setup: endpoint projects");
    assert(TopologyPenTool.projectWorldPt(m.vertices[m.edges[0][1]], vp, pb), "setup: endpoint projects");

    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    SDL_MouseButtonEvent e;
    e.x = cast(int)((pa.x + pb.x) * 0.5f);
    e.y = cast(int)((pa.y + pb.y) * 0.5f);

    static struct Row { PenMode mode; bool loop; PenGesture want; string why; }
    static immutable Row[] rows = [
        Row(PenMode.Move,      false, PenGesture.PlaceOrMove, "Move = the plain LMB gesture"),
        Row(PenMode.Move,      true,  PenGesture.MoveLoop,       "Move + Edge Loop = the RMB gesture"),
        Row(PenMode.Point,     false, PenGesture.PlaceOrMove, "Point = place-or-move"),
        Row(PenMode.Point,     true,  PenGesture.MoveLoop,       "Point on geometry follows Move"),
        Row(PenMode.Duplicate, false, PenGesture.Build,          "Duplicate = the Shift+LMB gesture"),
        Row(PenMode.Duplicate, true,  PenGesture.DupLoop,        "Duplicate + Edge Loop = the loop variant (gather + trim), the same mode's other half"),
        Row(PenMode.Remove,    false, PenGesture.Remove,         "Remove = the Ctrl+MMB gesture"),
        Row(PenMode.Remove,    true,  PenGesture.Remove,         "Remove + Edge Loop is still the Remove gesture — the loop flag reaches its EDGE primitive, it does not select a different gesture (task 0494)"),
        Row(PenMode.Split,     false, PenGesture.Split,          "Split = the MMB gesture"),
        Row(PenMode.Split,     true,  PenGesture.Split,          "Split ignores Edge Loop"),
        Row(PenMode.AddLoop,   false, PenGesture.AddLoop,        "Add Loop = the Shift+MMB gesture"),
        Row(PenMode.AddLoop,   true,  PenGesture.AddLoop,        "Add Loop ignores Edge Loop"),
        Row(PenMode.Smooth,    false, PenGesture.Smooth,         "Smoothing = the Shift+Ctrl+LMB gesture"),
        Row(PenMode.Smooth,    true,  PenGesture.SmoothLoop,     "Smoothing + Edge Loop = Shift+Ctrl+RMB"),
    ];

    foreach (r; rows) {
        auto t = new TopologyPenTool();
        t.meshSrc_   = () => &m;
        t.penMode_   = r.mode;
        t.edgeLoop_  = r.loop;
        t.onPlainLmbDown(e, vts);
        assert(t.gestureOn_[InputButton.Left] == r.want, r.why);
    }

    // Task 0486 (C-1/C-4) + 0487: for Duplicate, Edge Loop selects between the
    // mode's TWO variants — the pressed edge alone, or the gathered-and-trimmed
    // border run. One implementation each, both reached from the one
    // dispatcher, so they cannot drift. The reference reads `edgeLoop_` on the
    // Shift+LMB slot and FORCES it on Shift+RMB, which is why those two chords
    // are now just (mode=Duplicate, loop=...) rows in `kChordOv` rather than
    // two hand-wired gestures.
    {
        auto t1 = new TopologyPenTool();
        t1.meshSrc_ = () => &m;
        t1.penMode_ = PenMode.Duplicate;
        t1.onPlainLmbDown(e, vts);
        assert(t1.dupEdgeEdges_.length == 1,
            "Duplicate with the flag OFF arms exactly the pressed edge");
        assert(!t1.dupLoopArmed_, "and never the loop variant");

        auto t2 = new TopologyPenTool();
        t2.meshSrc_ = () => &m;
        t2.penMode_ = PenMode.Duplicate;
        t2.edgeLoop_ = true;
        t2.onPlainLmbDown(e, vts);
        assert(t2.dupLoopArmed_, "Duplicate with Edge Loop ON arms the loop variant");
        assert(t2.dupLoopEdges_.length >= 1,
            "and its set is the trimmed border run — never fewer than the pressed edge");
        assert(t2.dupEdgeEdges_.length == 0, "the single-edge variant must stay untouched");
    }

    // Edge Slide reroutes the Move family — and ONLY the Move family — to the
    // very gesture the Ctrl+LMB chord runs. Edge Loop wins when both are on
    // (there is no slide-a-whole-loop gesture to compose them into).
    foreach (mode; [PenMode.Move, PenMode.Point]) {
        auto t = new TopologyPenTool();
        t.meshSrc_   = () => &m;
        t.penMode_   = mode;
        t.edgeSlide_ = true;
        t.onPlainLmbDown(e, vts);
        assert(t.gestureOn_[InputButton.Left] == PenGesture.Slide, "Edge Slide must route the Move family to Slide");

        t.resetAllGestureArms();
        t.edgeLoop_ = true;
        t.onPlainLmbDown(e, vts);
        assert(t.gestureOn_[InputButton.Left] == PenGesture.MoveLoop, "Edge Loop must win over Edge Slide");
    }

    // Every OTHER mode ignores Edge Slide outright.
    foreach (mode; [PenMode.Duplicate, PenMode.Remove, PenMode.Split,
                    PenMode.AddLoop, PenMode.Smooth]) {
        auto t = new TopologyPenTool();
        t.meshSrc_   = () => &m;
        t.penMode_   = mode;
        t.edgeSlide_ = true;
        t.onPlainLmbDown(e, vts);
        assert(t.gestureOn_[InputButton.Left] != PenGesture.Slide,
            "Edge Slide must not leak into a non-Move-family mode");
    }
}

// ---------------------------------------------------------------------------
// The CHORD MODEL composes with the dropdown (task 0487) — the property the old
// table could not express and the reason for the refactor.
//
// Two halves, and the second is the one that used to be wrong:
//   * a chord that OVERRIDES the mode ignores the dropdown (Shift+MMB is Add
//     Loop whatever the dropdown says);
//   * a chord that does NOT override it runs the DROPDOWN's mode. Plain RMB is
//     that case — measured as "the dropdown's mode with the loop forced on",
//     where the old table hard-wired it to move-loop, so it stayed a move-loop
//     with the dropdown parked on Remove.
//
// Driven through the real `onToolAction` seam with a synthetic chord id, so the
// override resolution and the per-button booking are both exercised.
// ---------------------------------------------------------------------------
unittest {
    import mesh : makeGridPlane;
    import toolpipe.packets : SubjectPacket;

    Mesh m = makeGridPlane(3);
    auto vp = makeGridPlaneTestViewport();
    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    // A vertex pixel: every mode below resolves SOMETHING there, so the rows
    // differ by the routing decision and not by a pick miss.
    ImVec2 p0;
    assert(TopologyPenTool.projectWorldPt(m.vertices[0], vp, p0), "setup: v0 must project");
    SDL_MouseButtonEvent e;
    e.x = cast(int)p0.x; e.y = cast(int)p0.y;

    PenGesture press(TopoPenChord c, PenMode dropdown, bool loop = false, bool slide = false) {
        auto t = new TopologyPenTool();
        t.meshSrc_  = () => &m;
        t.penMode_  = dropdown;
        t.edgeLoop_ = loop;
        t.edgeSlide_ = slide;
        t.onToolAction(c, InputPhase.Down, e, vts);
        return t.gestureOn_[chordButton(c)];
    }

    // --- a mode-overriding chord ignores the dropdown entirely.
    foreach (dropdown; [PenMode.Move, PenMode.Remove, PenMode.Fill, PenMode.Smooth]) {
        assert(press(TopoPenChord.ShiftMmb, dropdown) == PenGesture.AddLoop,
            "Shift+MMB overrides the mode to Add Loop whatever the dropdown says");
        assert(press(TopoPenChord.CtrlMmb, dropdown) == PenGesture.Remove,
            "Ctrl+MMB overrides the mode to Remove whatever the dropdown says");
    }

    // --- a NON-overriding chord follows the dropdown. This is the row the old
    //     absolute table got wrong.
    assert(press(TopoPenChord.Rmb, PenMode.Move) == PenGesture.MoveLoop,
        "plain RMB with the dropdown on Move is a move-LOOP (the loop is forced)");
    assert(press(TopoPenChord.Rmb, PenMode.Remove) == PenGesture.Remove,
        "plain RMB with the dropdown on Remove must run REMOVE — under the old absolute "
      ~ "table it stayed a move-loop regardless");
    assert(press(TopoPenChord.Rmb, PenMode.Smooth) == PenGesture.SmoothLoop,
        "plain RMB with the dropdown on Smoothing is smooth+loop — its forced loop meets "
      ~ "the dropdown's mode");

    // --- the forced loop cannot be switched off by the user's flag...
    assert(press(TopoPenChord.Rmb, PenMode.Move, /*loop=*/false) == PenGesture.MoveLoop);
    assert(press(TopoPenChord.Rmb, PenMode.Move, /*loop=*/true)  == PenGesture.MoveLoop,
        "and the flag being on changes nothing for a chord that already forces it");

    // --- ...while a chord that does NOT force it reads the user's flag.
    assert(press(TopoPenChord.Lmb, PenMode.Move, /*loop=*/false) == PenGesture.PlaceOrMove);
    assert(press(TopoPenChord.Lmb, PenMode.Move, /*loop=*/true)  == PenGesture.MoveLoop,
        "the base slot honours Edge Loop — that is what FlagOv.FromUser means");

    // --- Ctrl+LMB forces Edge Slide; plain LMB honours the user's flag.
    assert(press(TopoPenChord.CtrlLmb, PenMode.Move) == PenGesture.Slide,
        "Ctrl+LMB forces Edge Slide on top of the dropdown's mode");
    assert(press(TopoPenChord.Lmb, PenMode.Move, false, /*slide=*/true) == PenGesture.Slide,
        "and the user's own Edge Slide reaches the base slot");

    // --- the gesture is booked against the chord's OWN button, so a MIDDLE
    //     chord cannot redirect a LEFT release.
    {
        auto t = new TopologyPenTool();
        t.meshSrc_ = () => &m;
        t.penMode_ = PenMode.Move;
        t.onToolAction(TopoPenChord.Lmb,    InputPhase.Down, e, vts);
        t.onToolAction(TopoPenChord.CtrlMmb, InputPhase.Down, e, vts);
        assert(t.gestureOn_[InputButton.Left]   == PenGesture.PlaceOrMove,
            "the LEFT booking must survive a MIDDLE chord fired during the drag");
        assert(t.gestureOn_[InputButton.Middle] == PenGesture.Remove,
            "and the MIDDLE booking is its own");
    }

    // --- task 0499: the two slots that override NOTHING. Each one must run
    //     the DROPDOWN's mode — the whole content of the measurement — and
    //     must NOT behave like the base slot of its own button.
    foreach (c; [TopoPenChord.CtrlRmb, TopoPenChord.ShiftCtrlMmb]) {
        assert(press(c, PenMode.Move)      == PenGesture.PlaceOrMove,
            "an unbound slot with the dropdown on Move runs a plain move");
        assert(press(c, PenMode.Remove)    == PenGesture.Remove,
            "…on Remove it removes");
        assert(press(c, PenMode.Split)     == PenGesture.Split,
            "…on Split it splits (the condition the capture ran in lockstep)");
        assert(press(c, PenMode.AddLoop)   == PenGesture.AddLoop);
        assert(press(c, PenMode.Duplicate) == PenGesture.Build);
        // Smoothing WITHOUT the loop — this is the assertion that fails if
        // either row is ever "fixed" into looking like its own button's base
        // slot: plain RMB forces the loop (-> SmoothLoop) and Ctrl+RMB does
        // not, and plain MMB forces Split where Shift+Ctrl+MMB does not.
        assert(press(c, PenMode.Smooth)    == PenGesture.Smooth,
            "an unbound slot does NOT force the loop the way its button's base slot may");
        // …and it still READS the user's own flags, like the base LMB slot.
        assert(press(c, PenMode.Smooth, /*loop=*/true) == PenGesture.SmoothLoop,
            "FromUser means the user's Edge Loop reaches the slot");
        assert(press(c, PenMode.Move, /*loop=*/false, /*slide=*/true) == PenGesture.Slide,
            "…and so does the user's Edge Slide");
    }
    // The distinction stated as a direct comparison, in the exact condition the
    // capture ran (dropdown = Move / Split): same button, different slot.
    assert(press(TopoPenChord.Rmb, PenMode.Move) != press(TopoPenChord.CtrlRmb, PenMode.Move),
        "plain RMB forces the loop, Ctrl+RMB does not — measured on the same rig");
    assert(press(TopoPenChord.Mmb, PenMode.Move) != press(TopoPenChord.ShiftCtrlMmb, PenMode.Move),
        "plain MMB forces Split, Shift+Ctrl+MMB followed the dropdown (measured: MOVE)");
    assert(press(TopoPenChord.Mmb, PenMode.Split) == press(TopoPenChord.ShiftCtrlMmb, PenMode.Split),
        "and with the dropdown ON Split the two agree — the other half of the lockstep");
}

// ---------------------------------------------------------------------------
// The 12-slot grid at the DEFAULT dropdown — the "nothing else moved"
// acceptance condition, restated for task 0499 exactly as task 0487 stated it:
// with the dropdown parked at its default (`move`, both flags off), every slot
// that existed before yields EXACTLY the gesture it yielded before, and the two
// new rows land on the base slot's own outcome (they override nothing, so at the
// default dropdown they cannot differ from plain LMB's routing).
//
// One table, all 12 rows, driven through the real `onToolAction` seam. A future
// edit that "tidies" the chord table by shifting an enum member or a row is a
// silent rebinding of everything after it (`kChordOv` is indexed BY the enum) —
// this is the pin that turns that into a failure.
// ---------------------------------------------------------------------------
unittest {
    import mesh : makeGridPlane;
    import toolpipe.packets : SubjectPacket;

    Mesh m = makeGridPlane(3);
    auto vp = makeGridPlaneTestViewport();
    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    ImVec2 p0;
    assert(TopologyPenTool.projectWorldPt(m.vertices[0], vp, p0), "setup: v0 must project");
    SDL_MouseButtonEvent e;
    e.x = cast(int)p0.x; e.y = cast(int)p0.y;

    static struct Slot { TopoPenChord chord; PenGesture want; string why; }
    immutable Slot[] grid = [
        Slot(TopoPenChord.Lmb,          PenGesture.PlaceOrMove, "plain LMB"),
        Slot(TopoPenChord.ShiftLmb,     PenGesture.Build,       "Shift+LMB = Duplicate, loop from the user (off)"),
        Slot(TopoPenChord.CtrlLmb,      PenGesture.Slide,       "Ctrl+LMB forces Edge Slide"),
        Slot(TopoPenChord.ShiftCtrlLmb, PenGesture.Smooth,      "Shift+Ctrl+LMB = Smoothing, no loop"),
        Slot(TopoPenChord.Mmb,          PenGesture.Split,       "plain MMB = Split"),
        Slot(TopoPenChord.ShiftMmb,     PenGesture.AddLoop,     "Shift+MMB = Add Loop"),
        Slot(TopoPenChord.CtrlMmb,      PenGesture.Remove,      "Ctrl+MMB = Remove"),
        Slot(TopoPenChord.Rmb,          PenGesture.MoveLoop,    "plain RMB = the dropdown + forced loop"),
        Slot(TopoPenChord.ShiftRmb,     PenGesture.DupLoop,     "Shift+RMB = Duplicate + forced loop"),
        Slot(TopoPenChord.ShiftCtrlRmb, PenGesture.SmoothLoop,  "Shift+Ctrl+RMB = Smoothing + forced loop"),
        // The two rows task 0499 wired. At the DEFAULT dropdown they are the
        // base slot's own outcome — that is what "overrides nothing" means, and
        // it is why wiring them cannot disturb any row above.
        Slot(TopoPenChord.CtrlRmb,      PenGesture.PlaceOrMove, "Ctrl+RMB follows the dropdown"),
        Slot(TopoPenChord.ShiftCtrlMmb, PenGesture.PlaceOrMove, "Shift+Ctrl+MMB follows the dropdown"),
    ];
    assert(grid.length == kChordOv.length,
        "every chord slot must appear in this pin — a new row without a row here is a gap");

    foreach (s; grid) {
        auto t = new TopologyPenTool();
        t.meshSrc_ = () => &m;   // default dropdown/flags: Move, loop off, slide off
        t.onToolAction(s.chord, InputPhase.Down, e, vts);
        assert(t.gestureOn_[chordButton(s.chord)] == s.want, s.why);
    }
}

// ---------------------------------------------------------------------------
// The router's RELEASE leg follows the press, not the dropdown (task 0483):
// a mode written mid-drag must not redirect the commit to a gesture nobody
// armed. Split is the probe — it arms on a vertex press and its `splitUp`
// disarms observably — and the dropdown is flipped to Move (whose UP leg is
// the entirely different `lmbPlaceOrMoveUp`) between the press and the
// release.
// ---------------------------------------------------------------------------
unittest {
    import mesh : makeGridPlane;
    import toolpipe.packets : SubjectPacket;

    auto t = new TopologyPenTool();
    Mesh m = makeGridPlane(3);
    t.meshSrc_ = () => &m;

    auto vp = makeGridPlaneTestViewport();
    ImVec2 p0;
    assert(TopologyPenTool.projectWorldPt(m.vertices[0], vp, p0), "setup: v0 must project");

    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    SDL_MouseButtonEvent e;
    e.x = cast(int)p0.x; e.y = cast(int)p0.y;

    t.penMode_ = PenMode.Split;
    assert(t.onPlainLmbDown(e, vts), "a Split-mode press on a vertex must arm");
    assert(t.splitArmed_ && t.splitSourceVert_ == 0, "Split must arm at the pressed vertex");
    assert(t.gestureOn_[InputButton.Left] == PenGesture.Split, "the press must record the Split gesture");

    // The dropdown moves mid-drag (this is reachable over HTTP at any time).
    t.penMode_ = PenMode.Move;

    assert(t.lmbModeUp(e, vts), "the release must still reach Split's own commit leg");
    assert(!t.splitArmed_, "Split's commit leg must have run and disarmed");
}

// ---------------------------------------------------------------------------
// params() — Smooth strength schema (reference parity,
// doc/tasks/work/0478-topopen-smooth-kernel.md): the measured `strength` attribute
// exposed as a real, bound, bounded Param. Defaults to the reference's own
// 1.0 (force factor 0.05 after the ÷20), binds directly to the field the
// Smooth kernel reads, declares `.enforceBounds()` so a headless `tool.attr`
// injection is clamped rather than honoured, and — like every other option on
// this tool — is sticky across `resyncSession()`.
// ---------------------------------------------------------------------------
unittest {
    import std.math : abs;

    auto t = new TopologyPenTool();

    auto ps = t.params();
    assert(ps[4].name == "smoothStrength");
    assert(ps[4].kind == Param.Kind.Float);
    assert(abs(ps[4].default_.f - 1.0f) < 1e-6f,
        "smoothStrength must default to 1.0 — the reference's own default, giving F = 1/20 = 0.05");
    assert(ps[4].fptr is &t.smoothStrength_, "the Param must bind directly to smoothStrength_");
    assert(ps[4].enforceBounds_,
        "smoothStrength must clamp injected values — an out-of-range force factor would be "
      ~ "honoured verbatim by the headless attr path otherwise");
    assert(ps[4].hints.hasMinF && ps[4].hints.hasMaxF
        && abs(ps[4].hints.minF - 0.0f) < 1e-6f && abs(ps[4].hints.maxF - 4.0f) < 1e-6f,
        "smoothStrength bounds must be declared as [0, 4] — `.enforceBounds()` clamps to the "
      ~ "hinted range, so a missing hint would silently disarm the clamp");

    assert(abs(t.smoothStrength_ - 1.0f) < 1e-6f, "must start at the default strength");

    t.smoothStrength_ = 0.5f;
    t.resyncSession();
    assert(abs(t.smoothStrength_ - 0.5f) < 1e-6f,
        "smoothStrength_ must survive resyncSession() — it is a sticky tool option, not "
      ~ "per-gesture arm state");
}

// ---------------------------------------------------------------------------
// params() / toolStateJson — the two DISPLAY toggles (task 0499): the
// reference's `showVertex`/`showEdge`, both measured default ON, published as
// plain sticky booleans. Nothing here is bounded or gated — they are the only
// two attributes in the reference's set whose behavior is measured to be
// "drawing only", which is what makes them portable when the numeric ones are
// not.
// ---------------------------------------------------------------------------
unittest {
    import std.json : JSONType;

    auto t = new TopologyPenTool();

    auto ps = t.params();
    assert(ps[5].name == "showVertex");
    assert(ps[5].kind == Param.Kind.Bool);
    assert(ps[5].default_.b == true, "showVertex must default ON — the measured default");
    assert(ps[5].bptr is &t.showVertex_, "the Param must bind directly to showVertex_");
    assert(ps[6].name == "showEdge");
    assert(ps[6].kind == Param.Kind.Bool);
    assert(ps[6].default_.b == true, "showEdge must default ON — the measured default");
    assert(ps[6].bptr is &t.showEdge_, "the Param must bind directly to showEdge_");

    // Defaults ON => a tool nobody touched draws exactly what it drew before
    // these rows existed.
    assert(t.showVertex_ && t.showEdge_, "both toggles must start ON");

    auto s0 = t.toolStateJson();
    assert(s0["hoverIndicator"]["showVertex"].type == JSONType.true_);
    assert(s0["hoverIndicator"]["showEdge"].type   == JSONType.true_);

    t.showVertex_ = false;
    t.resyncSession();
    assert(!t.showVertex_,
        "showVertex_ must survive resyncSession() — a sticky display option, not arm state");
    auto s1 = t.toolStateJson();
    assert(s1["hoverIndicator"]["showVertex"].type == JSONType.false_,
        "the live toggle must be observable from outside");
}

// ---------------------------------------------------------------------------
// hoverIndicatorElem — WHAT the toggles actually do (task 0499). `draw()`
// switches on this function, so this is the drawn outcome, pinned without an
// ImGui draw list.
//
// The load-bearing half is the SECOND assertion of each pair: turning a marker
// off must NOT change `hoverGrabElem_`, i.e. what a press grabs. These are
// display toggles; nothing measured says they disable the grab, and a knob that
// silently changed the grab target would be the exact failure mode task 0499
// exists to avoid.
// ---------------------------------------------------------------------------
unittest {
    auto t = new TopologyPenTool();

    // A resolved VERTEX target.
    t.hoverGrabElem_  = MoveElem.Vertex;
    t.hoverGrabIndex_ = 3;
    assert(t.hoverIndicatorElem() == MoveElem.Vertex, "ON by default -> the marker draws");
    t.showVertex_ = false;
    assert(t.hoverIndicatorElem() == MoveElem.None, "showVertex off -> nothing is painted");
    assert(t.hoverGrabElem_ == MoveElem.Vertex && t.hoverGrabIndex_ == 3,
        "…and the resolved grab target is untouched — the press still takes the vertex");
    // The OTHER toggle is not involved.
    t.showEdge_ = false;
    t.showVertex_ = true;
    assert(t.hoverIndicatorElem() == MoveElem.Vertex,
        "showEdge must not gate the vertex marker");

    // A resolved EDGE target, same shape.
    t.hoverGrabElem_  = MoveElem.Edge;
    t.hoverGrabIndex_ = 7;
    t.showEdge_ = true;
    assert(t.hoverIndicatorElem() == MoveElem.Edge);
    t.showEdge_ = false;
    assert(t.hoverIndicatorElem() == MoveElem.None, "showEdge off -> nothing is painted");
    assert(t.hoverGrabElem_ == MoveElem.Edge && t.hoverGrabIndex_ == 7,
        "…and the press still takes the edge");
    t.showVertex_ = false;
    t.showEdge_   = true;
    assert(t.hoverIndicatorElem() == MoveElem.Edge,
        "showVertex must not gate the edge line");

    // The FACE hatch has no toggle in the reference's two-flag set, so neither
    // flag may hide it. Guessing a third toggle into existence here is the
    // failure this asserts against.
    t.hoverGrabElem_  = MoveElem.Face;
    t.hoverGrabIndex_ = 1;
    t.showVertex_ = false;
    t.showEdge_   = false;
    assert(t.hoverIndicatorElem() == MoveElem.Face,
        "the face hatch is ungated — the reference has two display toggles, not three");

    // Nothing resolved stays nothing, either way.
    t.hoverGrabElem_  = MoveElem.None;
    t.hoverGrabIndex_ = -1;
    t.showVertex_ = true;
    t.showEdge_   = true;
    assert(t.hoverIndicatorElem() == MoveElem.None);
}

// ---------------------------------------------------------------------------
// onMouseButtonDown / onMouseButtonUp — NEGATIVE DISPATCH pin: Split does
// NOT do mid-edge insertion (doc/tasks/work/0480-topopen-addloop-middle.md).
// Drives the REAL dispatch path end-to-end — plain-MMB down on vertex A (0),
// plain-MMB up on the screen-space MIDPOINT of the opposite edge (2,3),
// never a vertex — mirroring the vertex<->vertex e2e test above exactly
// (same rig, same camera). Split is a vertex->vertex chord split, so this
// release must leave the mesh byte-identical with NO undo entry. Inserting a
// vertex partway along a crossed edge belongs to Add Loop, whose own
// `middle`/click-fraction law is pinned separately above and in
// tests/test_topopen_addloop_middle.d.
//
// This test previously asserted the OPPOSITE (Δv=+1/Δf=+1/one undo entry) —
// it encoded the wrong mode attachment and is inverted here deliberately,
// not weakened: the same real gesture is driven, and every count is still
// asserted exactly.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import toolpipe.packets : SubjectPacket;

    loadSDL();
    SDL_SetModState(cast(SDL_Keymod)0);

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_          = history;
    t.splitEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                    "mesh.topoPen_split", "Topology Split",
                                                    MeshEditScope.Geometry);

    Mesh m;
    t.meshSrc_ = () => &m;
    // Scaled up from the shipped vertex e2e's -0.3..0.3 rig to keep the
    // projected edge (2,3) comfortably longer than 2*topoPenSnapAcceptPx at
    // this camera distance — its screen-space MIDPOINT must land clearly
    // outside the DRAG-SNAP acceptance radius of EITHER endpoint (the release
    // resolves through `resolveSnapTargetVert`, whose reach is wider than the
    // press pick's — task 0496), so the release genuinely
    // resolves NO vertex (a snap to v2/v3 would turn this into an ordinary
    // vertex-target split and the no-op assertions below would be vacuous).
    m.addVertex(Vec3(-0.8f, 0, -0.8f));   // 0 A
    m.addVertex(Vec3( 0.8f, 0, -0.8f));   // 1
    m.addVertex(Vec3( 0.8f, 0,  0.8f));   // 2
    m.addVertex(Vec3(-0.8f, 0,  0.8f));   // 3
    // Wound toward the default View camera (above the XZ plane) for the same
    // reason the e2e Split rig is (task 0538): this block's rig GUARD asserts
    // that the midpoint pixel resolves no vertex, and on a back-facing quad
    // that guard would hold because NOTHING resolves — the guard, and every
    // no-op assertion it protects, would be vacuous.
    m.addFace([0u, 3u, 2u, 1u]);
    m.buildLoops();

    Viewport vp = view.viewport();
    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    // Task 0523: snapping ON, in a case whose whole subject is that the
    // release resolves NO vertex. With the master gate closed the release
    // resolves nothing whatever the pixel, the rig guard below would pass for
    // the wrong reason, and every no-op assertion after it would be vacuous —
    // which is exactly what this block's own header warns against.
    vts.put(penTestSnapOn());

    float sx0, sy0, ndcZ;
    assert(projectToWindowFull(m.vertices[0], vp, sx0, sy0, ndcZ),
        "setup: v0 must project on-screen for this rig");

    // Release pixel = the screen-space midpoint of the projected edge (2,3)
    // — NOT either endpoint's own pixel, so it never snaps to a vertex.
    ImVec2 p2, p3;
    assert(TopologyPenTool.projectWorldPt(m.vertices[2], vp, p2));
    assert(TopologyPenTool.projectWorldPt(m.vertices[3], vp, p3));
    int midX = cast(int)((p2.x + p3.x) * 0.5f), midY = cast(int)((p2.y + p3.y) * 0.5f);

    SDL_MouseButtonEvent eDown;
    eDown.button = SDL_BUTTON_MIDDLE;
    eDown.x = cast(int)sx0; eDown.y = cast(int)sy0;
    bool downConsumed = t.onMouseButtonDown(eDown, vts);
    assert(downConsumed, "plain-MMB press on a vertex must be consumed");
    assert(t.splitArmed_, "plain-MMB press on a vertex must arm Split");
    assert(t.splitSourceVert_ == 0, "must arm the pressed vertex (0) as the split source");

    // Guard the rig itself: the release pixel must resolve NO vertex, or the
    // no-op below would prove nothing about the removed edge branch. Asked of
    // the query the release ACTUALLY runs (`resolveSnapTargetVert`, 24px), not
    // of the narrower press pick — a guard weaker than the code path it guards
    // is not a guard.
    assert(t.resolveSnapTargetVert(midX, midY, vp) < 0,
        "setup: the edge midpoint pixel must be outside every vertex's drag-snap radius");

    auto before = MeshSnapshot.capture(m);

    SDL_MouseButtonEvent eUp;
    eUp.button = SDL_BUTTON_MIDDLE;
    eUp.x = midX; eUp.y = midY;
    bool upConsumed = t.onMouseButtonUp(eUp, vts);
    assert(upConsumed, "plain-MMB release on the edge midpoint must still be consumed");
    assert(!t.splitArmed_, "release must disarm Split regardless of outcome");

    auto after = MeshSnapshot.capture(m);
    assert(after.vertices == before.vertices && after.edges == before.edges
        && after.faces == before.faces,
        "Split must NOT insert a mid-edge vertex — a release on an edge is a byte-identical "
      ~ "no-op (that behaviour belongs to Add Loop)");
    assert(m.vertices.length == 4, "Δv=0 — no vertex may be created by a Split release");
    assert(m.faces.length    == 1, "Δf=0 — the quad must stay whole");
    assert(m.edges.length    == 4, "Δe=0 — no sub-edge and no chord may be created");
    assert(!history.canUndo(), "a no-op release must record no undo entry");

    SDL_SetModState(cast(SDL_Keymod)0);   // leave the shared SDL modifier global clean
}

// ---------------------------------------------------------------------------
// Fill mode V1 (task 0477 continuation, doc/topopen_fill_plan.md) — Tier-B
// tests. The `params()`/`mode` schema round-trip is already pinned right
// after the Add Loop `middle` option schema block above (mirroring
// `addLoopMiddle_`'s own precedent); everything below exercises
// `findFillRing`/`commitFill`/the dropdown-routed dispatch/the hover
// preview.
//
// Shared test idiom: every rig captures the target cell's OWN vertex array
// via `m.faces[i].dup` BEFORE deleting it, so the expected corner SET is
// read off the mesh itself rather than hand-derived from grid arithmetic
// (which this feature's own planning drift already showed is error-prone —
// see doc/topopen_fill_plan.md's line-citation warning).
// ---------------------------------------------------------------------------

version (unittest) private bool fillCellSetEq(const(uint)[] a, const(uint)[] b) {
    import std.algorithm : canFind;
    if (a.length != b.length) return false;
    foreach (v; a) if (!canFind(b, v)) return false;
    return true;
}

// F1 — interior single-cell gap: `makeGridPlane(3)` (16v, 9f, 24e) minus
// its CENTER face (i=1,j=1 — fully interior, all 4 sides border after
// removal). `findFillRing` must resolve exactly that cell from a cursor at
// its centroid; `commitFill` must cap it with ONE quad, reusing the 4
// existing corner verts (Δv=0), winding consistent with a neighbour (never
// a hardcoded axis — `makeGridPlane`'s cells wind -Y despite the source
// comment, doc's empirical finding #2). Also covers F7 (undo restores the
// exact pre-fill V/E/F).
unittest {
    import mesh : makeGridPlane;
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_         = history;
    t.fillEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                   "mesh.topoPen_fill", "Topology Fill",
                                                   MeshEditScope.Geometry);

    Mesh m = makeGridPlane(3);   // 4x4=16 verts, 3x3=9 quads, 24 edges
    assert(m.vertices.length == 16 && m.faces.length == 9);
    uint[] cellVerts = m.faces[4].dup;   // center cell (i=1,j=1) -- fully interior
    auto mask = new bool[](m.faces.length);
    mask[4] = true;
    m.deleteFacesByMask(mask, true, true);
    assert(m.faces.length == 8, "setup: the center face must be removed");
    assert(m.vertices.length == 16, "setup: no vertex is deleted (keepOrphans)");
    auto beforeFill = MeshSnapshot.capture(m);

    t.meshSrc_ = () => &m;
    t.penMode_ = PenMode.Fill;

    auto vp = makeGridPlaneTestViewport();
    Vec3 centroid = (m.vertices[cellVerts[0]] + m.vertices[cellVerts[1]]
                    + m.vertices[cellVerts[2]] + m.vertices[cellVerts[3]]) * 0.25f;
    ImVec2 cpix;
    assert(TopologyPenTool.projectWorldPt(centroid, vp, cpix),
        "setup: the gap cell's centroid must project on-screen");

    // The press pixel is the gap cell's own CENTROID -- as far from every
    // element of the mesh as the cell allows, and well outside
    // `topoPenPressPickPx`. That is deliberate and it is the load-bearing half
    // of this assertion (task 0507): the reference drops its press-pick gather
    // radius entirely in Fill mode, so a press at the bare centre of a gap
    // still resolves the cell. Gating `findFillRing`/`fillDown` on
    // `topoPenPressPickPx` to make Fill "consistent" with the other modes is
    // the exact regression this line catches -- see `source/constraint.d`'s
    // MODE-DEPENDENT paragraph.
    auto cell = t.findFillRing(cast(int)cpix.x, cast(int)cpix.y, vp);
    assert(cell.length == 4, "findFillRing must resolve the one interior gap cell "
        ~ "from a press at its bare centroid -- Fill's press has NO reach radius");
    assert(fillCellSetEq(cell, cellVerts),
        "findFillRing must return exactly the gap cell's own 4 corners");

    t.commitFill(cell);

    assert(m.faces.length == 9, "commitFill: the gap must be capped with exactly ONE new face");
    assert(m.vertices.length == 16, "commitFill: Δv=0 -- the cell's own corners are reused");
    assert(history.canUndo(), "a real fill must record one undo entry");

    // Locate the new face (the one whose vertex set == the gap cell's) and
    // check winding CONSISTENCY with a neighbour -- never a hardcoded
    // axis/sign: for every edge of the new face, any neighbour face
    // sharing that (undirected) edge must traverse it in the OPPOSITE
    // direction.
    int newFi = -1;
    foreach (fi, f; m.faces) {
        if (f.length == 4 && fillCellSetEq(f[], cellVerts)) { newFi = cast(int)fi; break; }
    }
    assert(newFi >= 0, "the newly-added face must contain exactly the cell's 4 verts");
    auto newFace = m.faces[newFi];
    foreach (i; 0 .. newFace.length) {
        uint u = newFace[i], v = newFace[(i + 1) % newFace.length];
        bool foundOpposite = false;
        foreach (fi, f; m.faces) {
            if (cast(int)fi == newFi) continue;
            foreach (k; 0 .. f.length) {
                uint a = f[k], b = f[(k + 1) % f.length];
                assert(!(a == u && b == v),
                    "the new face's winding must NOT match a neighbour's own direction on a "
                  ~ "shared edge (task 0477 continuation: makePolygonFromVerts autoOrient)");
                if (a == v && b == u) foundOpposite = true;
            }
        }
        assert(foundOpposite, "every edge of the new face must have a neighbour traversing it "
                             ~ "in the opposite direction");
    }

    // F7: undo restores the exact pre-fill V/E/F.
    history.undo();
    auto afterUndo = MeshSnapshot.capture(m);
    assert(afterUndo.vertices == beforeFill.vertices && afterUndo.edges == beforeFill.edges
        && afterUndo.faces == beforeFill.faces,
        "undo must restore the mesh byte-identical to its pre-fill state");
}

// F2 — single-cell notch: a hand-built 2-row x 4-col quad grid (3x5=15
// verts) with the MIDDLE row-0 cell (index 1 -- touches neither the west
// nor east mesh perimeter, so it opens exactly ONE mouth, north) removed.
// 3 of its 4 sides become border edges (the 4th, north, drops to 0
// incident faces -- a floating "mouth" edge, kept by
// `deleteFacesByMask(keepFloatingEdges:true)` -- the SAME contract the
// tool's own `removeFaceAt` always uses, so this is the FAITHFUL shape of
// a notch this tool itself would ever produce; not counted by
// `isEdgeBorder`'s n==1 predicate). `findFillRing` must still resolve the
// correct 4-vertex cell from the 3 surviving border edges, and
// `commitFill` must attach the new face to that already-present floating
// mouth edge (0 incident faces -> 1 -- Δe=0, the edge record itself is
// REUSED, never duplicated).
unittest {
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_         = history;
    t.fillEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                   "mesh.topoPen_fill", "Topology Fill",
                                                   MeshEditScope.Geometry);

    Mesh m;
    float[5] xs = [0.0f, 1.0f, 2.0f, 5.0f, 6.0f];
    float[3] zs = [0.0f, 1.0f, 2.0f];
    uint[5][3] idx;
    foreach (i; 0 .. 3)
        foreach (j; 0 .. 5)
            idx[i][j] = m.addVertex(Vec3(xs[j], 0, zs[i]));
    foreach (i; 0 .. 2)
        foreach (j; 0 .. 4)
            m.addFace([idx[i][j], idx[i][j + 1], idx[i + 1][j + 1], idx[i + 1][j]]);
    m.buildLoops();
    assert(m.faces.length == 8, "setup: the 2x4 grid must have 8 faces");

    uint[] cellVerts = m.faces[1].dup;   // middle row-0 cell -- neither west nor east corner
    auto mask = new bool[](m.faces.length);
    mask[1] = true;
    m.deleteFacesByMask(mask, true, true);
    assert(m.faces.length == 7, "setup: the notch cell must be removed");
    assert(m.vertices.length == 15, "setup: no vertex is deleted (keepOrphans)");
    size_t edgesBefore = m.edges.length;

    // Identify the mouth edge -- the one side of the cell with 0 incident
    // faces right after its own face was removed.
    int mouthEdge = -1;
    foreach (k; 0 .. 4) {
        uint ei = m.edgeIndex(cellVerts[k], cellVerts[(k + 1) % 4]);
        assert(ei != uint.max, "setup: every side of the removed cell must still exist as an "
                             ~ "edge (deleteFacesByMask keeps floating edges)");
        int nf = 0; foreach (fi; m.facesAroundEdge(ei)) ++nf;
        if (nf == 0) { mouthEdge = cast(int)ei; break; }
    }
    assert(mouthEdge >= 0, "setup: exactly one side of the notch cell must be a floating "
                         ~ "(0-face) mouth");

    t.meshSrc_ = () => &m;
    t.penMode_ = PenMode.Fill;

    auto vp = makeGridPlaneTestViewport();
    Vec3 centroid = (m.vertices[cellVerts[0]] + m.vertices[cellVerts[1]]
                    + m.vertices[cellVerts[2]] + m.vertices[cellVerts[3]]) * 0.25f;
    ImVec2 cpix;
    assert(TopologyPenTool.projectWorldPt(centroid, vp, cpix),
        "setup: the notch cell's centroid must project on-screen");

    auto cell = t.findFillRing(cast(int)cpix.x, cast(int)cpix.y, vp);
    assert(cell.length == 4, "findFillRing must resolve the notch cell from its 3 border edges");
    assert(fillCellSetEq(cell, cellVerts),
        "findFillRing must return exactly the notch cell's own 4 corners");

    t.commitFill(cell);

    assert(m.faces.length == 8, "commitFill: the notch must be capped with exactly ONE new face");
    assert(m.vertices.length == 15, "commitFill: Δv=0 -- the cell's own corners are reused");
    assert(m.edges.length == edgesBefore,
        "commitFill: the mouth is an ALREADY-PRESENT floating edge -- Δe=0, it is reused, "
      ~ "never duplicated");
    int nfAfter = 0; foreach (fi; m.facesAroundEdge(cast(uint)mouthEdge)) ++nfAfter;
    assert(nfAfter == 1,
        "commitFill: the mouth edge must gain exactly one incident face (the new fill face)");
    assert(history.canUndo(), "a real fill must record one undo entry");
}

// F3 — two SEPARATE (non-adjacent) single-cell gaps in the same mesh, one
// click fills ONE cell (owner decision 2: "one cell per click").
//
// NOTE on scope (revised after a post-e6ca77a review fix): TWO
// MUTUALLY-ADJACENT missing cells (sharing one now-gone middle edge) were
// investigated in detail; the outcome DEPENDS on whether the pair touches
// the mesh's own outer perimeter:
//   - INTERIOR adjacent pair (neither cell touches the mesh perimeter): now
//     resolves CORRECTLY, one true cell per click — see the dedicated
//     interior-adjacent-2-cell unittest right after this one. (An earlier
//     draft of THIS comment claimed the interior case also failed; that
//     was an incomplete-enumeration mistake in hand analysis, not a real
//     limitation — a full seed-edge enumeration finds a valid seed for
//     EACH true cell, and `findFillRing`'s closing-edge guard
//     — `m.edgeIndex(bp,ap) != ~0u` — is exactly what lets each true cell's
//     candidate win: the true cell closes on the shared middle edge, which
//     still EXISTS as a floating (0-face) edge, while the bogus
//     "skip-through" candidate's closing side is a non-edge diagonal and
//     is rejected outright.)
//   - PERIMETER adjacent pair (both cells touch the SAME outer mesh side,
//     e.g. a "2-cell-wide" notch along one edge of the mesh): still
//     resolves to `[]` — see the dedicated perimeter-adjacent-2-cell
//     unittest right after this one. Root cause: the shared "waist" vertex
//     between the two missing cells has ZERO border-edge incidences at all
//     (both its own mouth-facing side and the shared middle edge are
//     non-border), so it never even enters `findFillRing`'s
//     border-adjacency graph — no candidate mentioning it is EVER
//     generated, closing-edge guard or not. This is a real, acceptable V1
//     gap (falls under doc/topopen_fill_plan.md's own AF-1 "known
//     limitation" umbrella) — but is now at least a SAFE no-op rather than
//     the wrong bogus fill the guard was added to prevent.
//
// This test itself verifies owner decision 2's core promise ("one click,
// one cell, never both") on two gaps that are trivially, unambiguously
// resolvable: two separate single-cell interior gaps, far enough apart
// that neither's reconstruction can be confused with the other's.
unittest {
    import mesh : makeGridPlane;
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_         = history;
    t.fillEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                   "mesh.topoPen_fill", "Topology Fill",
                                                   MeshEditScope.Geometry);

    Mesh m = makeGridPlane(5);   // 6x6=36 verts, 5x5=25 quads
    assert(m.faces.length == 25);
    uint[] cellA = m.faces[6].dup;    // interior cell (i=1,j=1)
    uint[] cellB = m.faces[18].dup;   // a SEPARATE, non-adjacent interior cell (i=3,j=3)
    auto mask = new bool[](m.faces.length);
    mask[6] = true; mask[18] = true;
    m.deleteFacesByMask(mask, true, true);
    assert(m.faces.length == 23, "setup: both gap cells must be removed");
    assert(m.vertices.length == 36, "setup: no vertex is deleted (keepOrphans)");

    t.meshSrc_ = () => &m;
    t.penMode_ = PenMode.Fill;

    auto vp = makeGridPlaneTestViewport();
    Vec3 centA = (m.vertices[cellA[0]] + m.vertices[cellA[1]]
                + m.vertices[cellA[2]] + m.vertices[cellA[3]]) * 0.25f;
    Vec3 centB = (m.vertices[cellB[0]] + m.vertices[cellB[1]]
                + m.vertices[cellB[2]] + m.vertices[cellB[3]]) * 0.25f;
    ImVec2 pixA, pixB;
    assert(TopologyPenTool.projectWorldPt(centA, vp, pixA));
    assert(TopologyPenTool.projectWorldPt(centB, vp, pixB));

    auto foundA = t.findFillRing(cast(int)pixA.x, cast(int)pixA.y, vp);
    assert(foundA.length == 4, "a cursor over gap A must resolve exactly that cell");
    assert(fillCellSetEq(foundA, cellA),
        "must resolve ONLY gap A's own 4 corners, never gap B's");

    auto foundB = t.findFillRing(cast(int)pixB.x, cast(int)pixB.y, vp);
    assert(foundB.length == 4, "a cursor over gap B must resolve exactly that cell");
    assert(fillCellSetEq(foundB, cellB),
        "must resolve ONLY gap B's own 4 corners, never gap A's");

    // One click fills ONE cell -- the other remains an untouched gap,
    // fillable by a SECOND click (owner decision 2: "one cell per click").
    t.commitFill(foundA);
    assert(m.faces.length == 24, "commitFill must add exactly ONE face for gap A");

    auto foundBAfter = t.findFillRing(cast(int)pixB.x, cast(int)pixB.y, vp);
    assert(foundBAfter.length == 4, "gap B must still be found as a gap after gap A alone was filled");
    assert(fillCellSetEq(foundBAfter, cellB));

    t.commitFill(foundBAfter);
    assert(m.faces.length == 25, "commitFill must add exactly ONE more face for gap B");
    assert(m.vertices.length == 36, "both fills together are Δv=0 -- every corner is reused");
    assert(history.canUndo());
}

// F3-PERIMETER — two MUTUALLY-ADJACENT cells removed from the SAME mesh
// perimeter side (a 2-row x 4-col grid, middle row-0 cells at indices 1
// and 2, asymmetric widths 1 / 3).
//
// FIXTURE CHANGED BY TASK 0488, and this is the reviewed reason. The old
// expectation here was `[]` -- a deliberate no-op produced by V1's mandatory
// real-fourth-side guard, on a rig V1's border-edge-adjacency construction
// could not resolve at all (the shared "waist" vertex carries no border edge,
// so no V1 candidate ever mentioned it). The measured rule has NO
// fourth-side requirement and does not reconstruct cells from adjacency: it
// seeds on the pressed border edge and takes the nearest qualifying vertices,
// and the waist vertex qualifies here through the ISOLATED clause (both its
// remaining sides lost their last polygon, so it is on no polygon at all).
// The left cell's own four corners are exactly what the search returns, and
// the fill lands on the cell the cursor is in.
//
// So the change is a strict improvement in outcome, but it is NOT why it was
// made: it is what dropping a guard the reference does not have produces on
// this rig. Recorded as a changed fixture, not as a fix.
unittest {
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_         = history;
    t.fillEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                   "mesh.topoPen_fill", "Topology Fill",
                                                   MeshEditScope.Geometry);

    Mesh m;
    float[5] xs = [0.0f, 1.0f, 2.0f, 5.0f, 6.0f];
    float[3] zs = [0.0f, 1.0f, 2.0f];
    uint[5][3] idx;
    foreach (i; 0 .. 3)
        foreach (j; 0 .. 5)
            idx[i][j] = m.addVertex(Vec3(xs[j], 0, zs[i]));
    foreach (i; 0 .. 2)
        foreach (j; 0 .. 4)
            m.addFace([idx[i][j], idx[i][j + 1], idx[i + 1][j + 1], idx[i + 1][j]]);
    m.buildLoops();
    assert(m.faces.length == 8, "setup: the 2x4 grid must have 8 faces");

    uint[] leftVerts = m.faces[1].dup;   // width 1 -- retained only for the centroid pixel
    auto mask = new bool[](m.faces.length);
    mask[1] = true; mask[2] = true;
    m.deleteFacesByMask(mask, true, true);
    assert(m.faces.length == 6, "setup: both perimeter cells must be removed");
    auto before = MeshSnapshot.capture(m);

    t.meshSrc_ = () => &m;
    t.penMode_ = PenMode.Fill;

    auto vp = makeGridPlaneTestViewport();
    Vec3 leftC = (m.vertices[leftVerts[0]] + m.vertices[leftVerts[1]]
                + m.vertices[leftVerts[2]] + m.vertices[leftVerts[3]]) * 0.25f;
    ImVec2 leftPix;
    assert(TopologyPenTool.projectWorldPt(leftC, vp, leftPix));

    auto cell = t.findFillRing(cast(int)leftPix.x, cast(int)leftPix.y, vp);
    assert(cell.length == 4,
        "the measured rule resolves the LEFT cell of a perimeter 2-cell gap -- the waist "
      ~ "vertex qualifies as ISOLATED, and no fourth-side guard stands in the way");
    assert(fillCellSetEq(cell, leftVerts),
        "it must be the cell the CURSOR is in, never a span of both missing cells");

    t.commitFill(cell);
    auto after = MeshSnapshot.capture(m);
    assert(m.faces.length == 7, "exactly ONE face is added -- one cell per press");
    assert(m.vertices.length == before.vertices.length, "Dv=0 -- every corner is reused");
    assert(m.edges.length == before.edges.length,
        "De=0 here -- the left cell's fourth side survived the deletion as a floating edge");
    assert(history.canUndo(), "a real fill records one undo entry");
    assert(after.vertices == before.vertices,
        "a fill moves no vertex -- positions are byte-identical");
}

// F3-INTERIOR — the companion case: two MUTUALLY-ADJACENT cells removed
// from the MIDDLE of a bigger grid (neither touches the mesh perimeter).
// Here the closing-edge guard does the opposite job: it REJECTS the bogus
// cross-cell candidates (their closing side is a non-edge diagonal) while
// LETTING THROUGH each true single cell's own candidate (its closing side
// is the shared middle edge, which still EXISTS as a floating/0-face edge
// -- `deleteFacesByMask`'s `keepFloatingEdges` contract). A cursor over
// EITHER cell must resolve to exactly that ONE cell, never a span of both.
unittest {
    import mesh : makeGridPlane;
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_         = history;
    t.fillEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                   "mesh.topoPen_fill", "Topology Fill",
                                                   MeshEditScope.Geometry);

    Mesh m = makeGridPlane(4);   // 5x5=25 verts, 4x4=16 quads
    assert(m.faces.length == 16);
    uint[] leftVerts  = m.faces[5].dup;   // interior cell (i=1,j=1)
    uint[] rightVerts = m.faces[6].dup;   // adjacent interior cell (i=1,j=2) -- shares an edge
    auto mask = new bool[](m.faces.length);
    mask[5] = true; mask[6] = true;
    m.deleteFacesByMask(mask, true, true);
    assert(m.faces.length == 14, "setup: both interior cells must be removed");
    assert(m.vertices.length == 25, "setup: no vertex is deleted (keepOrphans)");

    t.meshSrc_ = () => &m;
    t.penMode_ = PenMode.Fill;

    auto vp = makeGridPlaneTestViewport();
    Vec3 leftC  = (m.vertices[leftVerts[0]]  + m.vertices[leftVerts[1]]
                 + m.vertices[leftVerts[2]]  + m.vertices[leftVerts[3]])  * 0.25f;
    Vec3 rightC = (m.vertices[rightVerts[0]] + m.vertices[rightVerts[1]]
                 + m.vertices[rightVerts[2]] + m.vertices[rightVerts[3]]) * 0.25f;
    ImVec2 leftPix, rightPix;
    assert(TopologyPenTool.projectWorldPt(leftC,  vp, leftPix));
    assert(TopologyPenTool.projectWorldPt(rightC, vp, rightPix));

    auto leftCell = t.findFillRing(cast(int)leftPix.x, cast(int)leftPix.y, vp);
    assert(leftCell.length == 4,
        "an interior adjacent-2-cell gap must still resolve the LEFT cell (the closing-edge "
      ~ "guard rejects the bogus span, but the true cell's own candidate survives)");
    assert(fillCellSetEq(leftCell, leftVerts),
        "must resolve ONLY the left cell's own 4 corners, never a span of both cells");

    auto rightCell = t.findFillRing(cast(int)rightPix.x, cast(int)rightPix.y, vp);
    assert(rightCell.length == 4, "must likewise resolve the RIGHT cell under its own cursor");
    assert(fillCellSetEq(rightCell, rightVerts),
        "must resolve ONLY the right cell's own 4 corners, never a span of both cells");

    t.commitFill(leftCell);
    assert(m.faces.length == 15, "commitFill must add exactly ONE face for the left cell");
    auto rightCellAfter = t.findFillRing(cast(int)rightPix.x, cast(int)rightPix.y, vp);
    assert(rightCellAfter.length == 4 && fillCellSetEq(rightCellAfter, rightVerts),
        "the right cell must still resolve correctly after the left cell alone was filled");
    t.commitFill(rightCellAfter);
    assert(m.faces.length == 16, "commitFill must add exactly ONE more face for the right cell");
    assert(m.vertices.length == 25, "both fills together are Δv=0 -- every corner is reused");
    assert(history.canUndo());
}

// F6 — no-op over a solid face / empty area. `makeGridPlane(3)` left FULLY
// INTACT (no gap anywhere): a cursor at the centroid of a genuinely
// INTERIOR face (i=1,j=1 -- every edge shared by 2 faces, none border)
// must resolve `[]`, and a cursor far off the mesh entirely must too.
// `commitFill([])` must be a clean no-op (no undo entry, mesh
// byte-identical).
unittest {
    import mesh : makeGridPlane;
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_         = history;
    t.fillEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                   "mesh.topoPen_fill", "Topology Fill",
                                                   MeshEditScope.Geometry);

    Mesh m = makeGridPlane(3);   // fully intact -- no gap anywhere
    uint[] solidVerts = m.faces[4].dup;   // the same "center" cell F1 removes, kept HERE
    t.meshSrc_ = () => &m;
    t.penMode_ = PenMode.Fill;
    auto beforeAll = MeshSnapshot.capture(m);

    auto vp = makeGridPlaneTestViewport();

    // (a) cursor at a genuinely interior, already-faced cell's centroid.
    Vec3 solidCentroid = (m.vertices[solidVerts[0]] + m.vertices[solidVerts[1]]
                         + m.vertices[solidVerts[2]] + m.vertices[solidVerts[3]]) * 0.25f;
    ImVec2 spix;
    assert(TopologyPenTool.projectWorldPt(solidCentroid, vp, spix));
    auto cellOverFace = t.findFillRing(cast(int)spix.x, cast(int)spix.y, vp);
    assert(cellOverFace.length == 0,
        "findFillRing must return [] over an already-faced INTERIOR cell (no border edges "
      ~ "nearby to seed a candidate from)");

    // (b) cursor far outside the mesh entirely.
    auto cellOverEmpty = t.findFillRing(-99999, -99999, vp);
    assert(cellOverEmpty.length == 0, "findFillRing must return [] over empty area");

    // (c) commitFill([]) / a miss must be a clean no-op.
    t.commitFill(cellOverFace);
    t.commitFill(null);
    auto afterAll = MeshSnapshot.capture(m);
    assert(afterAll.vertices == beforeAll.vertices && afterAll.edges == beforeAll.edges
        && afterAll.faces == beforeAll.faces,
        "commitFill must leave the mesh byte-identical on a miss/empty cell");
    assert(!history.canUndo(), "a miss/empty cell must record NO undo entry");
}

// F5/F9 — dropdown routing: plain-LMB is a NO-OP for Point's place/move path
// when Fill owns it, and vice versa. dropdown=Point must arm place/move
// exactly like pre-Fill behavior; dropdown=Fill must fill immediately
// (commit-on-DOWN) and arm NOTHING.
unittest {
    import mesh : makeGridPlane;
    import view : View;
    import editmode : EditMode;
    import toolpipe.packets : SubjectPacket;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_         = history;
    t.fillEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                   "mesh.topoPen_fill", "Topology Fill",
                                                   MeshEditScope.Geometry);

    Mesh m = makeGridPlane(3);
    uint[] cellVerts = m.faces[4].dup;
    auto mask = new bool[](m.faces.length);
    mask[4] = true;
    m.deleteFacesByMask(mask, true, true);
    t.meshSrc_ = () => &m;

    auto vp = makeGridPlaneTestViewport();
    Vec3 centroid = (m.vertices[cellVerts[0]] + m.vertices[cellVerts[1]]
                    + m.vertices[cellVerts[2]] + m.vertices[cellVerts[3]]) * 0.25f;
    ImVec2 cpix;
    assert(TopologyPenTool.projectWorldPt(centroid, vp, cpix));

    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    SDL_MouseButtonEvent e;
    e.x = cast(int)cpix.x; e.y = cast(int)cpix.y;

    // dropdown = Point: plain-LMB over the gap centroid must arm place/move
    // -- NEVER Fill -- byte-identical to pre-Fill behavior.
    t.penMode_ = PenMode.Point;
    int facesBefore = cast(int)m.faces.length;
    bool consumed = t.onPlainLmbDown(e, vts);
    assert(consumed, "plain-LMB must always be consumed");
    assert(t.placeArmed_ || t.moveArmed_,
        "Point mode must arm place/move, exactly like pre-Fill behavior");
    assert(cast(int)m.faces.length == facesBefore, "Point mode must not mutate the mesh on DOWN");
    t.placeArmed_ = false; t.moveArmed_ = false; t.grabbedVert_ = -1;

    // dropdown = Fill: the SAME press must fill the cell and arm NOTHING.
    t.penMode_ = PenMode.Fill;
    consumed = t.onPlainLmbDown(e, vts);
    assert(consumed, "plain-LMB must always be consumed");
    assert(!t.placeArmed_ && !t.moveArmed_,
        "Fill mode must never arm place/move -- it owns plain-LMB entirely");
    assert(cast(int)m.faces.length == facesBefore + 1,
        "Fill mode's plain-LMB press must commit the fill immediately (commit-on-DOWN)");
    assert(history.canUndo());
}

// F8 — hover preview state: `fillRing_` equals the cell (as a set) after
// the Fill-mode motion compute; `null` in every other mode, off any gap, and when
// ANY gesture is armed (mode ghosts win, mirroring `hoverOverMesh_`'s own
// precedence rule -- MANDATORY opponent fix #2's sibling gate, not nested
// inside `hoverOverMesh_`).
unittest {
    import mesh : makeGridPlane;
    import toolpipe.packets : SubjectPacket;

    auto t = new TopologyPenTool();
    Mesh m = makeGridPlane(3);
    uint[] cellVerts = m.faces[4].dup;
    auto mask = new bool[](m.faces.length);
    mask[4] = true;
    m.deleteFacesByMask(mask, true, true);
    t.meshSrc_ = () => &m;

    auto vp = makeGridPlaneTestViewport();
    Vec3 centroid = (m.vertices[cellVerts[0]] + m.vertices[cellVerts[1]]
                    + m.vertices[cellVerts[2]] + m.vertices[cellVerts[3]]) * 0.25f;
    ImVec2 cpix;
    assert(TopologyPenTool.projectWorldPt(centroid, vp, cpix));

    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    SDL_MouseMotionEvent e;
    e.x = cast(int)cpix.x; e.y = cast(int)cpix.y;

    // Move mode (the default): the preview must stay empty even directly over
    // a gap cell -- Fill's hatch is gated on the mode.
    t.onMouseMotion(e, vts);
    assert(t.fillRing_.length == 0, "a non-Fill mode must never populate the Fill preview");

    // Fill mode: the SAME motion must resolve exactly the gap cell.
    t.penMode_ = PenMode.Fill;
    t.onMouseMotion(e, vts);
    assert(t.fillRing_.length == 4, "Fill mode must resolve the gap cell under the cursor");
    assert(fillCellSetEq(t.fillRing_, cellVerts));

    // A gesture armed on ANY button must clear the preview even in Fill mode.
    t.dragArmed_ = true;
    t.onMouseMotion(e, vts);
    assert(t.fillRing_.length == 0, "an armed gesture must take precedence over the Fill preview");
    t.dragArmed_ = false;

    // Off any gap (far away) -> null, even in Fill mode.
    SDL_MouseMotionEvent eFar;
    eFar.x = -99999; eFar.y = -99999;
    t.onMouseMotion(eFar, vts);
    assert(t.fillRing_.length == 0, "a cursor far from every gap must clear the preview");
}

// Fill mode radius overlay -- pure LAW arithmetic (task 0477 continuation,
// a derived law; full provenance/disassembly kept in the PRIVATE toolcard,
// toolcards/topology_pen/fill_radius_law_capture.md, never in this tracked
// source): radius = max(euclidean(cursor, edgeEndpointA),
// euclidean(cursor, edgeEndpointB)), screen-space pixels. A 3-4-5/6-8-10
// pair of right triangles off the SAME cursor pins both the per-endpoint
// Euclidean arithmetic and the max() tiebreak (never sum/average/first-arg)
// with hand-checkable numbers -- the draw itself isn't unit-testable, but
// this arithmetic, extracted as a pure static helper, is.
unittest {
    import std.math : abs, sqrt;

    auto cursor = ImVec2(0, 0);
    auto a = ImVec2(3, 4);     // distance 5 from cursor
    auto b = ImVec2(-6, 8);    // distance 10 from cursor -- farther

    float r = TopologyPenTool.fillHoverRadiusPx(cursor.x, cursor.y, a, b);
    assert(abs(r - 10.0f) < 1e-4, "radius must be the FARTHER endpoint's distance, not the nearer");

    // Order-independence: swapping which argument is farther must not
    // change the result (max, not "first argument wins").
    float rSwapped = TopologyPenTool.fillHoverRadiusPx(cursor.x, cursor.y, b, a);
    assert(abs(rSwapped - 10.0f) < 1e-4, "radius must be order-independent (max, not positional)");

    // Cursor coincident with the NEARER endpoint: radius collapses to
    // exactly the farther endpoint's own distance (0 max'd with a
    // positive value), not 0 and not a sum.
    float rAtA = TopologyPenTool.fillHoverRadiusPx(a.x, a.y, a, b);
    float expected = sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y));
    assert(abs(rAtA - expected) < 1e-3,
        "radius at a coincident endpoint must equal the OTHER endpoint's own distance");
}

// Fill mode radius overlay -- hover-time integration (task 0477
// continuation): `fillRadiusValid_`/`fillRadiusPx_` populate alongside
// `fillRing_` in `onMouseMotion`'s Fill-mode branch, off the screen-nearest
// BORDER EDGE (not the candidate cell's corners). False/unset in Draw
// mode, off any border edge, and when ANY gesture is armed -- mirrors the
// F8 `fillRing_` test above, same precedence rules.
unittest {
    import mesh : makeGridPlane;
    import toolpipe.packets : SubjectPacket;
    import std.math : abs;

    auto t = new TopologyPenTool();
    Mesh m = makeGridPlane(3);
    uint[] cellVerts = m.faces[4].dup;
    auto mask = new bool[](m.faces.length);
    mask[4] = true;
    m.deleteFacesByMask(mask, true, true);
    t.meshSrc_ = () => &m;

    auto vp = makeGridPlaneTestViewport();

    // Hover pixel = the screen-space MIDPOINT of one of the gap's own
    // border edges (cellVerts[0]-cellVerts[1]) -- lies exactly ON that
    // projected segment (distance 0 in SCREEN space, by construction), so
    // it is unambiguously the screen-nearest border edge regardless of
    // perspective distortion.
    ImVec2 p0, p1;
    assert(TopologyPenTool.projectWorldPt(m.vertices[cellVerts[0]], vp, p0));
    assert(TopologyPenTool.projectWorldPt(m.vertices[cellVerts[1]], vp, p1));
    ImVec2 hoverPix = ImVec2((p0.x + p1.x) * 0.5f, (p0.y + p1.y) * 0.5f);

    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    SDL_MouseMotionEvent e;
    e.x = cast(int)hoverPix.x; e.y = cast(int)hoverPix.y;

    // Move mode (the default): no radius overlay, even directly over a border edge.
    t.onMouseMotion(e, vts);
    assert(!t.fillRadiusValid_, "a non-Fill mode must never populate the radius overlay");

    // Fill mode: the SAME motion must resolve the radius against THIS
    // edge's own two endpoints, matching the pure law exactly.
    t.penMode_ = PenMode.Fill;
    t.onMouseMotion(e, vts);
    assert(t.fillRadiusValid_, "Fill mode must resolve a radius when hovering a border edge");
    float expected = TopologyPenTool.fillHoverRadiusPx(cast(float)e.x, cast(float)e.y, p0, p1);
    assert(abs(t.fillRadiusPx_ - expected) < 1e-2,
        "radius must equal max(dist to e0, dist to e1) for the hovered border edge");

    // A gesture armed on ANY button must clear the overlay even in Fill mode.
    t.dragArmed_ = true;
    t.onMouseMotion(e, vts);
    assert(!t.fillRadiusValid_, "an armed gesture must take precedence over the radius overlay");
    t.dragArmed_ = false;

    // Off any border edge (far away) -> invalid, even in Fill mode.
    SDL_MouseMotionEvent eFar;
    eFar.x = -99999; eFar.y = -99999;
    t.onMouseMotion(eFar, vts);
    assert(!t.fillRadiusValid_, "a cursor far from every border edge must clear the overlay");
}

// ---------------------------------------------------------------------------
// FILL — the measured candidate rule (task 0488). Every block below pins a
// clause that the SHIPPED rule got wrong, and every one of them FAILS on that
// shipped rule. Provenance for each clause is the private toolcard, never
// this file.
//
// Shared rig helpers keep the arithmetic hand-checkable: all rigs are planar
// (y = 0) under `makeGridPlaneTestViewport`, which looks straight down, so a
// world (x, z) offset is a screen offset and every distance quoted in a
// comment can be read off the coordinates.
// ---------------------------------------------------------------------------

// The pure screen-space predicates the rule is built from, on hand numbers.
unittest {
    // segmentsProperlyCross — an X crosses; a T-junction does NOT (the
    // measured word is "properly": both parameters strictly inside (0,1)),
    // and neither do parallels, disjoint pairs, or a shared endpoint. The
    // endpoint cases are load-bearing: a candidate that is itself a corner of
    // the polygon being tested must survive, and it only does because
    // touching is not crossing.
    assert(TopologyPenTool.segmentsProperlyCross(
               ImVec2(-1, 0), ImVec2(1, 0), ImVec2(0, -1), ImVec2(0, 1)),
           "an X must cross");
    assert(!TopologyPenTool.segmentsProperlyCross(
               ImVec2(0, 0), ImVec2(0, 1), ImVec2(-1, 0), ImVec2(1, 0)),
           "a T-junction touching at a segment END is NOT a proper crossing");
    assert(!TopologyPenTool.segmentsProperlyCross(
               ImVec2(-1, 0), ImVec2(1, 0), ImVec2(-1, 1), ImVec2(1, 1)),
           "parallels never cross");
    assert(!TopologyPenTool.segmentsProperlyCross(
               ImVec2(-1, 0), ImVec2(1, 0), ImVec2(5, -1), ImVec2(5, 1)),
           "disjoint segments never cross");
    assert(!TopologyPenTool.segmentsProperlyCross(
               ImVec2(0, 0), ImVec2(1, 1), ImVec2(0, 0), ImVec2(1, -1)),
           "a shared endpoint is not a crossing");
    assert(!TopologyPenTool.segmentsProperlyCross(
               ImVec2(0, 0), ImVec2(2, 0), ImVec2(1, 0), ImVec2(3, 0)),
           "collinear overlap is not a PROPER crossing");

    // screenQuadConvex — the shape test. A square passes either way round; a
    // bowtie (the SAME four points in the other cyclic order) fails, which is
    // exactly what makes the two-order search do real work; a collinear
    // corner fails, keeping a degenerate cycle out of the build.
    auto p00 = ImVec2(0, 0), p10 = ImVec2(1, 0), p11 = ImVec2(1, 1), p01 = ImVec2(0, 1);
    assert(TopologyPenTool.screenQuadConvex(p00, p10, p11, p01), "a square is convex");
    assert(TopologyPenTool.screenQuadConvex(p01, p11, p10, p00),
           "convexity is winding-agnostic — all four corners same sign, either sign");
    assert(!TopologyPenTool.screenQuadConvex(p00, p10, p01, p11),
           "the bowtie order of the same four points must FAIL");
    assert(!TopologyPenTool.screenQuadConvex(
               ImVec2(0, 0), ImVec2(1, 0), ImVec2(2, 0), ImVec2(1, 1)),
           "a collinear corner is neither sign — reject");
    // A dart (one point inside the triangle of the other three) is convex in
    // NO cyclic order, which is how the search refuses outright rather than
    // building a self-overlapping facet.
    auto inside = ImVec2(0.5f, 0.2f);
    assert(!TopologyPenTool.screenQuadConvex(p00, p10, inside, p01));
    assert(!TopologyPenTool.screenQuadConvex(p00, p10, p01, inside));
}

// The bridge: a quad across a gap whose closing side is NOT a mesh edge.
//
// FAILS ON THE OLD RULE, which is the point. The shipped rule reconstructed a
// cell from BORDER-EDGE ADJACENCY and required the fourth side to be a real
// mesh edge, so it could never leave the bar it seeded on: two topologically
// disconnected bars had no candidate at all and the press was a no-op. The
// reference has no such requirement and was measured building exactly this.
//
// Rig: two lone quads facing each other across a gap in x, both border on all
// four sides. Cursor between them but nearer bar A, so A's facing edge is the
// seed and both of B's facing corners are the only things in reach.
version (unittest) private Mesh makeFillBridgeRig(out uint[4] barA, out uint[4] barB) {
    Mesh m;
    // Bar A (left), corners in cycle order.
    barA[0] = m.addVertex(Vec3(-0.6f, 0, -0.2f));
    barA[1] = m.addVertex(Vec3(-0.2f, 0, -0.2f));
    barA[2] = m.addVertex(Vec3(-0.2f, 0,  0.2f));
    barA[3] = m.addVertex(Vec3(-0.6f, 0,  0.2f));
    // Bar B (right).
    barB[0] = m.addVertex(Vec3( 0.2f, 0, -0.2f));
    barB[1] = m.addVertex(Vec3( 0.6f, 0, -0.2f));
    barB[2] = m.addVertex(Vec3( 0.6f, 0,  0.2f));
    barB[3] = m.addVertex(Vec3( 0.2f, 0,  0.2f));
    m.addFace([barA[0], barA[1], barA[2], barA[3]]);
    m.addFace([barB[0], barB[1], barB[2], barB[3]]);
    m.buildLoops();
    return m;
}

unittest {
    import view : View;
    import editmode : EditMode;
    import std.algorithm : canFind;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_         = history;
    t.fillEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                   "mesh.topoPen_fill", "Topology Fill",
                                                   MeshEditScope.Geometry);

    uint[4] barA, barB;
    Mesh m = makeFillBridgeRig(barA, barB);
    t.meshSrc_ = () => &m;
    t.penMode_ = PenMode.Fill;

    auto vp = makeGridPlaneTestViewport();
    ImVec2 cur;
    assert(TopologyPenTool.projectWorldPt(Vec3(-0.05f, 0, 0), vp, cur));

    // The closing side does not exist as an edge before the fill — that is
    // the whole premise, asserted rather than assumed.
    assert(m.edgeIndex(barA[1], barB[0]) == ~0u, "setup: no closing edge may exist yet");
    assert(m.edgeIndex(barA[2], barB[3]) == ~0u, "setup: nor the other one");
    immutable size_t e0 = m.edges.length;

    // The seed really is bar A's facing edge, not a vertex press.
    immutable int seed = t.fillSeedEdge(cast(int)cur.x, cast(int)cur.y, vp);
    assert(seed >= 0, "the press must classify as a BORDER-EDGE press");
    assert((m.edges[seed][0] == barA[1] && m.edges[seed][1] == barA[2])
        || (m.edges[seed][0] == barA[2] && m.edges[seed][1] == barA[1]),
        "the seed must be bar A's facing edge");

    auto ring = t.findFillRing(cast(int)cur.x, cast(int)cur.y, vp);
    assert(ring.length == 4, "the measured rule bridges the gap — the old rule declined here");

    // SEEDS OCCUPY SLOTS 0 AND 1, in the EDGE'S OWN STORED ORDER (measured:
    // not sorted, not cursor-relative). The old rule put the seed edge's two
    // endpoints in slots 1 and 2, so this line alone fails on it.
    assert(ring[0] == m.edges[seed][0] && ring[1] == m.edges[seed][1],
        "slots 0 and 1 are the pressed edge's endpoints, in the edge's own stored order");

    assert(canFind(ring, barB[0]) && canFind(ring, barB[3]),
        "the two corners of the OTHER, disconnected bar must be the other two slots");

    t.commitFill(ring);
    assert(m.faces.length == 3, "the bridge must be built as exactly one new facet");
    assert(m.vertices.length == 8, "Dv=0 — a bridge reuses existing corners");
    assert(m.edges.length == e0 + 2, "De=+2 — both closing sides are created by the build");
    assert(history.canUndo(), "a real fill records one undo entry");
}

// `range` is a GATHER multiplier and nothing else: below the rig's own
// threshold the press refuses, above it builds, and FURTHER above it builds
// THE SAME THING — the four-nearest cap absorbs the extra reach. Measured as
// a ratio, so it needs no camera model; here it needs no pixel arithmetic
// either, only the same rig at three settings.
//
// FAILS ON THE OLD RULE, which had no reach of any kind (it was purely
// topological) and therefore could not vary with this attribute at all.
unittest {
    import std.algorithm : canFind;

    auto t = new TopologyPenTool();
    uint[4] barA, barB;
    Mesh m = makeFillBridgeRig(barA, barB);
    t.meshSrc_ = () => &m;
    t.penMode_ = PenMode.Fill;

    auto vp = makeGridPlaneTestViewport();
    ImVec2 cur;
    assert(TopologyPenTool.projectWorldPt(Vec3(-0.05f, 0, 0), vp, cur));
    immutable int cx = cast(int)cur.x, cy = cast(int)cur.y;

    // Below the threshold: the seeds are ~0.25 from the cursor and the far
    // bar's corners ~0.32, so a multiplier of 1 cannot reach them.
    t.fillRange_ = 1.0f;
    assert(t.findFillRing(cx, cy, vp).length == 0,
        "below the rig's own threshold the gesture refuses — only the two seeds are in reach");

    t.fillRange_ = 1.5f;
    auto atDefault = t.findFillRing(cx, cy, vp);
    assert(atDefault.length == 4, "above the threshold it builds");

    // Well above: bar A's far corners and bar B's far corners all come into
    // reach, and the answer does not move. Two independent reasons, both
    // measured — the reject discards anything on the far side of the seed's
    // own polygon, and the nearest-four cap evicts whatever is left over.
    t.fillRange_ = 3.0f;
    auto atTriple = t.findFillRing(cx, cy, vp);
    assert(atTriple == atDefault,
        "more reach changes NOTHING once the cap absorbs it — same ring, same order");
    assert(!canFind(atTriple, barA[0]) && !canFind(atTriple, barA[3]),
        "the seed bar's own far corners are never picked up, however wide the reach");

    // Zero reach is the extreme of the same law, not a special case.
    t.fillRange_ = 0.0f;
    assert(t.findFillRing(cx, cy, vp).length == 0, "range 0 gathers nothing — refuse");
}

// An ISOLATED vertex — one on no polygon at all — is a legal corner, and it
// BEATS the gap's own far corners when it is nearer. Measured directly, with
// the candidate's polygon count of 0 printed beside it, and built into armed
// rings 150 times over.
//
// FAILS ON THE OLD RULE twice over: that rule enumerated candidates as
// BORDER-EDGE NEIGHBOURS of the seed's endpoints, so a vertex with no
// polygon (and therefore no border edge) could never be reached at all, and
// on this rig it returns the hole's own four corners instead.
//
// Also pins the ORDER contract, which is a second thing the old rule got
// wrong: the pressed edge's two endpoints are slots 0 and 1 IN THE EDGE'S OWN
// STORED ORDER (the old rule put them in slots 1 and 2), and the returned
// array is the cyclic order the shape test ACCEPTED — asserted as "this order
// is screen-convex and the slot-2/3 swap of it is not", which pins the
// two-order search without depending on which of the two won.
unittest {
    import mesh : makeGridPlane;
    import view : View;
    import editmode : EditMode;
    import std.algorithm : canFind;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_         = history;
    t.fillEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                   "mesh.topoPen_fill", "Topology Fill",
                                                   MeshEditScope.Geometry);

    Mesh m = makeGridPlane(3);
    uint[] holeVerts = m.faces[4].dup;          // the centre cell's own 4 corners
    auto mask = new bool[](m.faces.length);
    mask[4] = true;
    m.deleteFacesByMask(mask, true, true);

    // Two vertices INSIDE the hole, on no polygon whatsoever — nearer to the
    // cursor than the hole's own far corners, and far enough from it that the
    // press still resolves an EDGE and not a vertex.
    immutable uint isoL = m.addVertex(Vec3(-0.28f, 0,  0.28f));
    immutable uint isoR = m.addVertex(Vec3( 0.28f, 0,  0.28f));
    assert(m.vertices.length == 18);

    t.meshSrc_ = () => &m;
    t.penMode_ = PenMode.Fill;

    auto vp = makeGridPlaneTestViewport();
    ImVec2 cur;
    assert(TopologyPenTool.projectWorldPt(Vec3(0, 0, -0.05f), vp, cur));
    immutable int cx = cast(int)cur.x, cy = cast(int)cur.y;

    immutable int seed = t.fillSeedEdge(cx, cy, vp);
    assert(seed >= 0, "an isolated vertex sitting farther than the border edge must not "
                    ~ "steal the press");

    auto ring = t.findFillRing(cx, cy, vp);
    assert(ring.length == 4);
    assert(ring[0] == m.edges[seed][0] && ring[1] == m.edges[seed][1],
        "slots 0 and 1 are the pressed edge's endpoints, in the edge's own stored order");
    assert(canFind(ring, isoL) && canFind(ring, isoR),
        "BOTH isolated vertices are corners — they are the two nearest survivors");

    // The hole's own FAR corners lose to them, which is what makes this a
    // ranking result and not merely "isolated vertices are allowed".
    uint[] farCorners;
    foreach (v; holeVerts)
        if (v != ring[0] && v != ring[1]) farCorners ~= v;
    assert(farCorners.length == 2, "setup: the seed edge accounts for two of the four corners");
    foreach (v; farCorners)
        assert(!canFind(ring, v),
            "the gap's own far corners are FARTHER than the isolated pair and must be evicted");

    // The returned array IS the accepted cyclic order: convex as returned,
    // and not convex with slots 2 and 3 exchanged. Exactly one of the two
    // orders the search tries can hold, so this pins the search's output
    // without depending on which one won.
    ImVec2[4] sp;
    foreach (k; 0 .. 4) assert(TopologyPenTool.projectWorldPt(m.vertices[ring[k]], vp, sp[k]));
    assert(TopologyPenTool.screenQuadConvex(sp[0], sp[1], sp[2], sp[3]),
        "the returned order is the one the shape test accepted");
    assert(!TopologyPenTool.screenQuadConvex(sp[0], sp[1], sp[3], sp[2]),
        "and the other of the two tried orders is the one it rejected");

    immutable size_t e0 = m.edges.length;
    t.commitFill(ring);
    assert(m.faces.length == 9, "exactly one facet is built");
    assert(m.vertices.length == 18, "Dv=0 — the isolated vertices are REUSED as corners");
    assert(m.edges.length == e0 + 3,
        "De=+3 — three of the four sides did not exist, and a fill creates them");
    assert(history.canUndo());
}

// THE SCREEN-CROSSING REJECT, isolated by the one experiment that isolates
// it: the SAME rig, the SAME seed edge, the SAME two candidates in reach, and
// the cursor moved across that edge. Outside the gap the candidates are on
// the far side of the seed's own polygon and every one of them is rejected —
// the press refuses. Inside the gap nothing is in the way and the same two
// build the facet.
//
// The reach is asserted, not assumed, on the refusing side: the candidate IS
// within the gather radius and is dropped anyway, so nothing but the reject
// can account for it. Without this clause a distance ranking picks different
// corners on three quarters of all searches, which is why it is tested as its
// own contrast pair rather than folded into another rig.
unittest {
    import mesh : makeGridPlane;
    import std.algorithm : canFind;
    import std.math : hypot;

    auto t = new TopologyPenTool();
    Mesh m = makeGridPlane(3);
    auto mask = new bool[](m.faces.length);
    mask[4] = true;
    m.deleteFacesByMask(mask, true, true);

    // Two isolated vertices just INSIDE the hole, near its bottom side.
    immutable uint isoR = m.addVertex(Vec3( 0.15f, 0, -0.15f));
    immutable uint isoL = m.addVertex(Vec3(-0.15f, 0, -0.15f));

    t.meshSrc_ = () => &m;
    t.penMode_ = PenMode.Fill;
    auto vp = makeGridPlaneTestViewport();

    // OUTSIDE the gap, just past the hole's bottom border edge.
    ImVec2 outside;
    assert(TopologyPenTool.projectWorldPt(Vec3(0, 0, -0.36f), vp, outside));
    immutable int ox = cast(int)outside.x, oy = cast(int)outside.y;

    immutable int seedOut = t.fillSeedEdge(ox, oy, vp);
    assert(seedOut >= 0, "the press outside the gap still resolves the same border edge");

    // The reach covers the candidates — so the refusal below is NOT a reach
    // refusal. Computed from the very law the search uses.
    ImVec2 pa, pb, pIso;
    assert(TopologyPenTool.projectWorldPt(m.vertices[m.edges[seedOut][0]], vp, pa));
    assert(TopologyPenTool.projectWorldPt(m.vertices[m.edges[seedOut][1]], vp, pb));
    assert(TopologyPenTool.projectWorldPt(m.vertices[isoR], vp, pIso));
    immutable float reach =
        1.5f * TopologyPenTool.fillHoverRadiusPx(cast(float)ox, cast(float)oy, pa, pb);
    assert(hypot(pIso.x - ox, pIso.y - oy) < reach,
        "setup: the candidate is comfortably INSIDE the gather radius");

    assert(t.findFillRing(ox, oy, vp).length == 0,
        "every candidate is on the far side of the seed's own polygon — all rejected, refuse");

    // INSIDE the gap, 0.06 world units away, same seed edge, same reach.
    ImVec2 inside;
    assert(TopologyPenTool.projectWorldPt(Vec3(0, 0, -0.30f), vp, inside));
    immutable int ix = cast(int)inside.x, iy = cast(int)inside.y;
    immutable int seedIn = t.fillSeedEdge(ix, iy, vp);
    assert(seedIn == seedOut, "setup: the pair must differ ONLY in which side of the edge "
                             ~ "the cursor is on");

    auto ring = t.findFillRing(ix, iy, vp);
    assert(ring.length == 4, "with nothing in the way the same two candidates build the facet");
    assert(canFind(ring, isoR) && canFind(ring, isoL),
        "and they are exactly the two that were rejected from the other side");

    ImVec2[4] sp;
    foreach (k; 0 .. 4) assert(TopologyPenTool.projectWorldPt(m.vertices[ring[k]], vp, sp[k]));
    assert(TopologyPenTool.screenQuadConvex(sp[0], sp[1], sp[2], sp[3]),
        "the returned order is the accepted one");
}

// THE COUNT GATE, and the triangle it lets through. A rig that reaches
// exactly THREE: with `quadOnly` on the press refuses; with it off the same
// press builds a TRIANGLE, and the three-path runs no shape test at all.
//
// FAILS ON THE OLD RULE, which had no count gate, no attribute, and could
// only ever return four corners or nothing.
version (unittest) private Mesh makeFillTripleRig(out uint[4] bar, out uint loose) {
    Mesh m;
    bar[0] = m.addVertex(Vec3(-0.6f, 0, -0.2f));
    bar[1] = m.addVertex(Vec3(-0.2f, 0, -0.2f));
    bar[2] = m.addVertex(Vec3(-0.2f, 0,  0.2f));
    bar[3] = m.addVertex(Vec3(-0.6f, 0,  0.2f));
    m.addFace([bar[0], bar[1], bar[2], bar[3]]);
    loose  = m.addVertex(Vec3(0.2f, 0, 0));      // isolated, on no polygon
    m.buildLoops();
    return m;
}

unittest {
    import view : View;
    import editmode : EditMode;
    import std.algorithm : canFind;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_         = history;
    t.fillEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                   "mesh.topoPen_fill", "Topology Fill",
                                                   MeshEditScope.Geometry);

    uint[4] bar; uint loose;
    Mesh m = makeFillTripleRig(bar, loose);
    t.meshSrc_ = () => &m;
    t.penMode_ = PenMode.Fill;

    auto vp = makeGridPlaneTestViewport();
    ImVec2 cur;
    assert(TopologyPenTool.projectWorldPt(Vec3(-0.05f, 0, 0), vp, cur));
    immutable int cx = cast(int)cur.x, cy = cast(int)cur.y;

    assert(t.fillQuadOnly_, "the measured default is ON");
    assert(t.findFillRing(cx, cy, vp).length == 0,
        "three in reach and quads-only: the count gate refuses");

    t.fillQuadOnly_ = false;
    auto tri = t.findFillRing(cx, cy, vp);
    assert(tri.length == 3, "with the gate off, exactly three is a build");
    immutable int seed = t.fillSeedEdge(cx, cy, vp);
    assert(tri[0] == m.edges[seed][0] && tri[1] == m.edges[seed][1],
        "the pressed edge is still slots 0 and 1 — and still a side of the facet");
    assert(tri[2] == loose, "the third corner is the one candidate in reach");

    immutable size_t e0 = m.edges.length;
    t.commitFill(tri);
    assert(m.faces.length == 2, "a TRIANGLE is built");
    assert(m.faces[1].length == 3);
    assert(m.vertices.length == 5, "Dv=0");
    assert(m.edges.length == e0 + 2, "De=+2 — the two new sides");
    assert(history.canUndo());
}

// A REFUSAL IS DESTRUCTIVE. The shipped behaviour was a clean no-op; the
// measured one grabs the pressed border edge and moves it. Ported as an arm
// of this tool's own Move gesture on that edge, so the drag and the release
// run the already-measured Move law and the whole thing undoes in one step.
//
// FAILS ON THE OLD RULE, whose `fillDown` armed nothing whatsoever on a miss.
unittest {
    import view : View;
    import editmode : EditMode;
    import toolpipe.packets : SubjectPacket;
    import std.algorithm : canFind;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_         = history;
    t.fillEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                   "mesh.topoPen_fill", "Topology Fill",
                                                   MeshEditScope.Geometry);

    uint[4] bar; uint loose;
    Mesh m = makeFillTripleRig(bar, loose);
    t.meshSrc_ = () => &m;
    t.penMode_ = PenMode.Fill;

    auto vp = makeGridPlaneTestViewport();
    ImVec2 cur;
    assert(TopologyPenTool.projectWorldPt(Vec3(-0.05f, 0, 0), vp, cur));

    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    SDL_MouseButtonEvent e;
    e.x = cast(int)cur.x; e.y = cast(int)cur.y;

    immutable int seed = t.fillSeedEdge(e.x, e.y, vp);
    assert(seed >= 0);
    immutable size_t f0 = m.faces.length;

    // quads-only ON: the search refuses at three, and the press falls
    // through to grabbing the pressed border edge.
    assert(t.onPlainLmbDown(e, vts), "a Fill press is always consumed");
    assert(t.moveArmed_, "the refusal must GRAB the pressed edge, not do nothing");
    assert(t.moveElem_ == MoveElem.Edge, "and it grabs an EDGE, never a vertex or a face");
    assert(t.moveVerts_.length == 2
        && canFind(t.moveVerts_, m.edges[seed][0]) && canFind(t.moveVerts_, m.edges[seed][1]),
        "the grabbed set is exactly the PRESSED border edge's two endpoints");
    assert(m.faces.length == f0, "the press itself mutates nothing — the move writes on drag");
    assert(!history.canUndo(), "and records nothing until the release");
    assert(!t.placeArmed_, "Fill never falls through to PLACE");
    t.resetAllGestureArms();

    // quads-only OFF: the same press builds instead, and arms nothing.
    t.fillQuadOnly_ = false;
    assert(t.onPlainLmbDown(e, vts));
    assert(m.faces.length == f0 + 1, "a resolved ring commits on DOWN");
    assert(!t.moveArmed_, "a press that BUILT must not also grab the edge");
}

// THE POST-BUILD CLEANUP: a fill CONSUMES the degenerate polygons it
// swallows — a LINE polygon (2 corners) lying along a new side, and a POINT
// polygon (1 corner) sitting at a new corner. Measured as part of the build
// itself, inside the same undo step.
//
// FAILS ON THE OLD RULE, which had no cleanup pass at all (and, on this rig,
// no candidate either).
//
// This clause is INERT on meshes vibe3d produces: nothing here creates a
// polygon with fewer than three corners, and loose retopo geometry is modelled
// as bare edges and orphan vertices instead — which are not polygons and are
// deliberately untouched. The rig therefore plants both degenerate polygons
// by hand, the way an importer that does carry them would deliver them.
unittest {
    import view : View;
    import editmode : EditMode;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_         = history;
    t.fillEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                   "mesh.topoPen_fill", "Topology Fill",
                                                   MeshEditScope.Geometry);

    uint[4] barA, barB;
    Mesh m = makeFillBridgeRig(barA, barB);
    // A line polygon along one future side, and a point polygon at a future
    // corner. Both are legal storage here; neither is reachable by any vibe3d
    // editing path today.
    m.addFace([barA[1], barB[0]]);
    m.addFace([barB[3]]);
    m.buildLoops();
    assert(m.faces.length == 4, "setup: two quads, one line polygon, one point polygon");

    t.meshSrc_ = () => &m;
    t.penMode_ = PenMode.Fill;

    auto vp = makeGridPlaneTestViewport();
    ImVec2 cur;
    assert(TopologyPenTool.projectWorldPt(Vec3(-0.05f, 0, 0), vp, cur));

    // The degenerate polygons must not disturb the search: their corners
    // qualify through the border clause exactly as before (a vertex on a
    // 2-corner polygon and on a bordered quad is still a border vertex).
    auto ring = t.findFillRing(cast(int)cur.x, cast(int)cur.y, vp);
    assert(ring.length == 4, "the bridge still resolves with degenerate polygons present");

    t.commitFill(ring);

    assert(m.faces.length == 3,
        "one facet built, and BOTH degenerate polygons consumed by it — net 4 - 2 + 1");
    foreach (const ref f; m.faces)
        assert(f.length >= 3, "no line or point polygon may survive on the new ring");
    assert(m.vertices.length == 8,
        "consuming a degenerate polygon must not eat the corner it sat on");
    assert(history.canUndo(), "the cleanup rides inside the fill's single undo entry");

    // And undo restores all four polygons, degenerate ones included.
    history.undo();
    assert(m.faces.length == 4, "undo restores the consumed polygons too");
}

// UNBOUNDED IS NOT UNARBITRATED. Fill's press has no reach radius — that is
// what lets a press at the bare centre of a gap, nowhere near anything, cap
// the cell. But whatever else is NEARER still wins the press, and only an
// EDGE press can fill: a recording caught a press at a hole's centre
// resolving an isolated vertex sitting inside that hole, and nothing
// happening.
//
// FAILS ON THE OLD RULE, which consulted no pick at all and capped the cell
// from that pixel regardless of what was sitting in it.
unittest {
    import mesh : makeGridPlane;
    import toolpipe.packets : SubjectPacket;

    auto t = new TopologyPenTool();
    Mesh m = makeGridPlane(3);
    auto mask = new bool[](m.faces.length);
    mask[4] = true;
    m.deleteFacesByMask(mask, true, true);
    t.meshSrc_ = () => &m;
    t.penMode_ = PenMode.Fill;

    auto vp = makeGridPlaneTestViewport();
    ImVec2 cur;
    assert(TopologyPenTool.projectWorldPt(Vec3(0, 0, 0), vp, cur));   // the hole's centre
    immutable int cx = cast(int)cur.x, cy = cast(int)cur.y;

    // With nothing in the hole, the centre press reaches the border edge
    // however far away it is — Fill's press has no radius.
    assert(t.fillSeedEdge(cx, cy, vp) >= 0,
        "an empty gap's centre must still resolve a border edge at ANY distance");
    assert(t.findFillRing(cx, cy, vp).length == 4, "and cap the cell");

    // Drop one isolated vertex right under the cursor. It is now the nearest
    // element, so the press is a VERTEX press and Fill has no path from one.
    m.addVertex(Vec3(0, 0, 0));
    assert(t.fillSeedEdge(cx, cy, vp) == -1,
        "a nearer vertex takes the press, and a vertex press cannot fill");
    assert(t.findFillRing(cx, cy, vp).length == 0);

    // And that press does nothing at all — not a fill, and not the
    // destructive refusal either, which belongs to a border-EDGE press.
    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);
    SDL_MouseButtonEvent e;
    e.x = cx; e.y = cy;
    immutable size_t f0 = m.faces.length;
    assert(t.onPlainLmbDown(e, vts), "still consumed — Fill owns the slot");
    assert(m.faces.length == f0, "no facet");
    assert(!t.moveArmed_ && !t.placeArmed_, "and nothing armed");
}

// ---------------------------------------------------------------------------
// THE RING GATE (task 0532) — the last gate on a FORMED ring, and the
// strictest thing in the search (it accepted 76 of 270 formed rings on the
// recording). Its two clauses, its scope, and its ≤2-corner exemption, on
// hand-checkable planar rigs under `makeGridPlaneTestViewport` (looks straight
// down, so a world (x, z) offset IS a screen offset).
//
// FAILS ON THE SHIPPED RULE, which had no gate here at all — every ring below
// that must be refused was built.
// ---------------------------------------------------------------------------

// CLAUSE 2 (a ring side properly crossing an incident polygon's edge) and its
// SCOPE. Both halves matter and they are tested against each other: the same
// crossing refuses when the crossed polygon carries a ring vertex and is
// ACCEPTED when it does not.
//
// DECODED-UNEXERCISED upstream: clause 2 fired zero times in the 270 recorded
// rings (it reached its last comparison 133 times, always past the incident
// edge's own extent). It is ported from the read; this block is the first
// thing anywhere that makes it fire.
unittest {
    Mesh m;
    // Q1 — the incident quad. `q0` is the ring's only shared corner, so the
    // SUBSET clause can never be what refuses anything below.
    immutable uint q0 = m.addVertex(Vec3(0, 0, 0));
    immutable uint q1 = m.addVertex(Vec3(1, 0, 0));
    immutable uint q2 = m.addVertex(Vec3(1, 0, 1));
    immutable uint q3 = m.addVertex(Vec3(0, 0, 1));
    m.addFace([q0, q1, q2, q3]);

    // The crossing pair: the side a→b runs along z = 0.5 from x = 2 to
    // x = 0.5, straight through Q1's right edge (x = 1, z in [0,1]) at
    // (1, 0.5) — both parameters strictly inside.
    immutable uint a = m.addVertex(Vec3(2.0f,  0, 0.5f));
    immutable uint b = m.addVertex(Vec3(0.5f,  0, 0.5f));
    // The clean pair: everything below z = 0, touching Q1 only at q0.
    immutable uint c = m.addVertex(Vec3(2.0f,  0, -0.5f));
    immutable uint d = m.addVertex(Vec3(2.0f,  0, -2.2f));
    m.buildLoops();

    auto vp = makeGridPlaneTestViewport();
    // Identity aim space: this block's rig has no layer transform, so the
    // composed viewport is field-identical to `vp` (task 0619 §2.3 permits
    // `ModelSpace.world()` inside a unittest block; production code in this
    // file must not name it).
    const vpAimId = aimSpace(vp, ModelSpace.world());

    assert(TopologyPenTool.ringRefusedByIncidentPolygon(&m, [q0, a, b], vpAimId),
        "a ring side that properly crosses an INCIDENT polygon's edge is refused");
    assert(!TopologyPenTool.ringRefusedByIncidentPolygon(&m, [q0, c, d], vpAimId),
        "the same ring shape clear of every incident edge is accepted -- sharing a "
        ~ "corner with a polygon is not by itself a refusal");

    // SCOPE. Q2 carries NO ring vertex, so it is outside the gate however
    // squarely a ring side cuts it: the side c→d (x = 2, z from -0.5 to -2.2)
    // crosses Q2's top edge at (2, -1) and its bottom edge at (2, -1.5), both
    // strictly inside, and the verdict must not move.
    immutable uint r0 = m.addVertex(Vec3(1.5f, 0, -1.5f));
    immutable uint r1 = m.addVertex(Vec3(2.5f, 0, -1.5f));
    immutable uint r2 = m.addVertex(Vec3(2.5f, 0, -1.0f));
    immutable uint r3 = m.addVertex(Vec3(1.5f, 0, -1.0f));
    m.addFace([r0, r1, r2, r3]);
    m.buildLoops();

    ImVec2 pc, pd, pr2, pr3;
    assert(TopologyPenTool.projectWorldPt(m.vertices[c],  vp, pc));
    assert(TopologyPenTool.projectWorldPt(m.vertices[d],  vp, pd));
    assert(TopologyPenTool.projectWorldPt(m.vertices[r2], vp, pr2));
    assert(TopologyPenTool.projectWorldPt(m.vertices[r3], vp, pr3));
    assert(TopologyPenTool.segmentsProperlyCross(pc, pd, pr3, pr2),
        "setup: the ring side really does cut the non-incident polygon's edge");

    assert(!TopologyPenTool.ringRefusedByIncidentPolygon(&m, [q0, c, d], vpAimId),
        "the gate never looks past the polygons incident to a ring vertex -- a ring "
        ~ "side may cross a distant face's edge freely");
}

// The ≤2-CORNER EXEMPTION, and it is exactly clause 2 that it exempts (a
// polygon with two corners or fewer can never contain a whole ring, so the
// subset clause cannot reach it either way).
//
// DECODED-UNEXERCISED upstream: the recorded rig had no line or point
// polygons. It is carried because `commitFill` CREATES that situation here —
// `consumeDegeneratePolysOnRing` deletes exactly such polygons off the new
// ring — so on this substrate it is reachable in a way it was not there.
//
// The two halves differ ONLY in the corner count of the polygon carrying the
// crossed segment, so nothing else can explain the flip.
version (unittest)
private Mesh makeRingGateLinePolyRig(out uint[3] ring, out uint cutA, out uint cutB) {
    Mesh m;
    immutable uint q0 = m.addVertex(Vec3(0, 0, 0));
    immutable uint q1 = m.addVertex(Vec3(1, 0, 0));
    immutable uint q2 = m.addVertex(Vec3(1, 0, 1));
    immutable uint q3 = m.addVertex(Vec3(0, 0, 1));
    m.addFace([q0, q1, q2, q3]);
    immutable uint c = m.addVertex(Vec3(2.0f, 0, -0.5f));
    immutable uint d = m.addVertex(Vec3(2.0f, 0, -2.2f));
    // The segment c→e (z = -0.5, x from 2 to 0) cuts the ring side d→q0
    // (z = -1.1x) at x ≈ 0.4545 — both parameters ≈ 0.773, strictly inside.
    immutable uint e = m.addVertex(Vec3(0.0f, 0, -0.5f));
    ring = [q0, c, d];
    cutA = c; cutB = e;
    return m;
}

unittest {
    auto vp = makeGridPlaneTestViewport();
    // Identity aim space: this block's rig has no layer transform, so the
    // composed viewport is field-identical to `vp` (task 0619 §2.3 permits
    // `ModelSpace.world()` inside a unittest block; production code in this
    // file must not name it).
    const vpAimId = aimSpace(vp, ModelSpace.world());

    uint[3] ring; uint cutA, cutB;
    Mesh line = makeRingGateLinePolyRig(ring, cutA, cutB);
    line.addFace([cutA, cutB]);                 // a LINE polygon: two corners
    line.buildLoops();
    assert(!TopologyPenTool.ringRefusedByIncidentPolygon(&line, ring[], vpAimId),
        "a polygon of two corners is exempt from the whole gate, crossing or not");

    uint[3] ring2; uint cutA2, cutB2;
    Mesh tri = makeRingGateLinePolyRig(ring2, cutA2, cutB2);
    immutable uint apex = tri.addVertex(Vec3(1.0f, 0, -0.2f));
    tri.addFace([cutA2, cutB2, apex]);          // the SAME segment, now eligible
    tri.buildLoops();
    assert(TopologyPenTool.ringRefusedByIncidentPolygon(&tri, ring2[], vpAimId),
        "give that identical segment a third corner and the crossing clause bites");
}

// CLAUSE 1 (SUBSET), EXECUTED END TO END — and the point of this block is that
// it separates the GATE from the guard that has been masking it.
//
// The 270-row corpus shows NO observable divergence: on that rig our own
// manifold guard happens to decline the strict-subset rings anyway. So a test
// that only showed the same outcome would prove nothing. This one builds the
// structural counterexample instead — a ring the measured gate REFUSES and
// `Mesh.makePolygonFromVerts` ACCEPTS — and asserts those two facts SEPARATELY:
//
//   * the search, gate and all, returns nothing;
//   * `commitFill` handed that very ring BUILDS the polygon, because the
//     duplicate-face guard is length-gated (4 corners vs 6) and no ring side
//     yet carries two faces.
//
// A single hexagonal face does it. The press at the midpoint of side 0–1 walks
// the whole real search: the seed resolves, exactly two more corners are in
// reach, the count gate passes at four, the shape test accepts — and the ring
// is a STRICT subset of the hexagon, which is the whole difference between
// "subset" and "duplicate face" as the measured word.
unittest {
    import view : View;
    import editmode : EditMode;
    import std.math : cos, sin, PI;

    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.history_         = history;
    t.fillEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                   "mesh.topoPen_fill", "Topology Fill",
                                                   MeshEditScope.Geometry);

    Mesh m;
    uint[6] h;
    foreach (k; 0 .. 6) {
        immutable float ang = cast(float)k * cast(float)(PI / 3.0);
        h[k] = m.addVertex(Vec3(cos(ang), 0, sin(ang)));
    }
    m.addFace([h[0], h[1], h[2], h[3], h[4], h[5]]);
    m.buildLoops();
    assert(m.faces.length == 1 && m.faces[0].length == 6, "setup: one hexagonal face");

    t.meshSrc_ = () => &m;
    t.penMode_ = PenMode.Fill;
    t.fillRange_ = 3.0f;      // reach 1.5 world units: h2/h5 in (1.323), h3/h4 out (1.803)

    auto vp = makeGridPlaneTestViewport();
    // Identity aim space: this block's rig has no layer transform, so the
    // composed viewport is field-identical to `vp` (task 0619 §2.3 permits
    // `ModelSpace.world()` inside a unittest block; production code in this
    // file must not name it).
    const vpAimId = aimSpace(vp, ModelSpace.world());
    ImVec2 cur;
    assert(TopologyPenTool.projectWorldPt((m.vertices[h[0]] + m.vertices[h[1]]) * 0.5f, vp, cur));
    immutable int cx = cast(int)cur.x, cy = cast(int)cur.y;

    // (1) the seed is side 0–1.
    immutable int seed = t.fillSeedEdge(cx, cy, vp);
    assert(seed >= 0, "the midpoint of a hexagon side is a border-EDGE press");
    immutable uint sa = m.edges[seed][0], sb = m.edges[seed][1];
    assert((sa == h[0] && sb == h[1]) || (sa == h[1] && sb == h[0]),
        "setup: and it is the side the cursor sits on");

    // (2) exactly two more corners are in reach, so the count gate passes at
    // four with no eviction at all — read off the search's own radius law.
    ImVec2 pa, pb;
    assert(TopologyPenTool.projectWorldPt(m.vertices[sa], vp, pa));
    assert(TopologyPenTool.projectWorldPt(m.vertices[sb], vp, pb));
    immutable float reach =
        3.0f * TopologyPenTool.fillHoverRadiusPx(cast(float)cx, cast(float)cy, pa, pb);
    size_t inReach = 0;
    foreach (k; 2 .. 6) {
        ImVec2 pk;
        assert(TopologyPenTool.projectWorldPt(m.vertices[h[k]], vp, pk));
        if (hypot(pk.x - cx, pk.y - cy) <= reach) ++inReach;
    }
    assert(inReach == 2, "setup: h2 and h5 are in reach, h3 and h4 are not");

    // (3) the shape test would accept — one of the two cyclic orders the
    // search tries is convex, exactly as the search asks it.
    ImVec2[4] sp;
    assert(TopologyPenTool.projectWorldPt(m.vertices[sa],   vp, sp[0]));
    assert(TopologyPenTool.projectWorldPt(m.vertices[sb],   vp, sp[1]));
    assert(TopologyPenTool.projectWorldPt(m.vertices[h[2]], vp, sp[2]));
    assert(TopologyPenTool.projectWorldPt(m.vertices[h[5]], vp, sp[3]));
    uint[] ring;
    if (TopologyPenTool.screenQuadConvex(sp[0], sp[1], sp[2], sp[3]))
        ring = [sa, sb, h[2], h[5]];
    else {
        assert(TopologyPenTool.screenQuadConvex(sp[0], sp[1], sp[3], sp[2]),
            "setup: the shape test accepts one of its two cyclic orders");
        ring = [sa, sb, h[5], h[2]];
    }

    // (4) the gate refuses it, and the reason is the SUBSET clause: all four
    // corners are corners of the hexagon, and it has six.
    assert(TopologyPenTool.ringRefusedByIncidentPolygon(&m, ring, vpAimId),
        "every ring corner is a corner of the incident hexagon -- a STRICT subset, "
        ~ "and the gate refuses subsets, not just duplicates");

    // (5) so the search returns nothing. With (1)-(3) established, the gate is
    // the only stage left that can have refused.
    assert(t.findFillRing(cx, cy, vp).length == 0,
        "the search forms the ring and the gate then refuses it");

    // (6) THE MASKING TEST, and the reason this block exists. Hand the very
    // same ring to the commit and BOTH of our own guards wave it through --
    // so the gate is doing real work here, not agreeing with something we
    // already had.
    assert(m.faces.length == 1);
    t.commitFill(ring);
    assert(m.faces.length == 2,
        "our own guards ACCEPT this ring: the duplicate-face guard is length-gated "
        ~ "(4 vs 6) and no ring side yet carries two faces");
    assert(m.faces[1].length == 4 && m.vertices.length == 6,
        "and what they build is a quad lying inside the existing face, reusing its corners");
    assert(history.canUndo());
}

// ---------------------------------------------------------------------------
// Plain-LMB press on an EDGE -> arms an EDGE move, and NEVER Place
// (task 0484, superseding doc/tasks/done/0482-topopen-move-nonvertex.md).
//
// The regression class 0482 closed: `onPlainLmbDown` resolved its Move target
// with `findSourceVertex` (VERTICES only), so a press aimed at an EDGE
// resolved nothing and fell through to Place — the release then committed a
// stray `mesh.addVertex` at the background-snapped cursor point. 0482 fixed
// that by DECLINING the press, because what an edge press should do was
// unmeasured at the time. 0484 measures it: the press grabs the edge and
// moves it. The half this test still pins unchanged is the important one —
// such a press must never, ever arm Place.
//
// The mesh-level proof (the edge's two endpoints actually move, one undo
// entry) needs a real background surface + GL and lives in the HTTP test
// (tests/test_topopen_move_nonvertex_decline.d).
//
// Pixel = the SCREEN-SPACE midpoint of grid edge 0-1: distance 0 from that
// projected segment by construction, while `makeGridPlane(3)`'s cell is ~53px
// wide under `makeGridPlaneTestViewport` so both endpoints sit ~26px away —
// outside the pen's press-pick reach (`topoPenPressPickPx`, 8px at scale 1).
// Asserted below rather than assumed, so a future viewport/grid change cannot
// silently turn this into a Move test.
// `pickPrimaryFace` answers -1 here (no `gpu_` under a bare `dub test`), so
// this exercises the EDGE term of the gate in isolation.
unittest {
    import mesh : makeGridPlane;
    import toolpipe.packets : SubjectPacket;
    import std.math : hypot;

    auto t = new TopologyPenTool();
    Mesh m = makeGridPlane(3);
    t.meshSrc_ = () => &m;

    auto vp = makeGridPlaneTestViewport();
    ImVec2 p0, p1;
    assert(TopologyPenTool.projectWorldPt(m.vertices[0], vp, p0), "setup: v0 must project");
    assert(TopologyPenTool.projectWorldPt(m.vertices[1], vp, p1), "setup: v1 must project");
    ImVec2 mid = ImVec2((p0.x + p1.x) * 0.5f, (p0.y + p1.y) * 0.5f);

    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    SDL_MouseButtonEvent e;
    e.x = cast(int)mid.x; e.y = cast(int)mid.y;

    // Setup precondition: the press pixel must be OUTSIDE snap range of every
    // vertex, or this would be testing Move, not the edge/face fall-through.
    assert(t.findSourceVertex(e.x, e.y, vp) < 0,
        "setup: the edge-midpoint pixel must resolve NO vertex within topoPenPressPickPx");
    assert(t.findRingSeedEdge(e.x, e.y, vp) >= 0,
        "setup: the edge-midpoint pixel must resolve the edge itself");
    assert(hypot(mid.x - p0.x, mid.y - p0.y) > topoPenPressPickPx(vp),
        "setup: the midpoint must be farther than the snap radius from endpoint 0");

    immutable size_t vBefore = m.vertices.length;
    immutable size_t eBefore = m.edges.length;
    immutable size_t fBefore = m.faces.length;

    assert(t.penMode_ == PenMode.Move, "setup: must be in the default Move mode");
    immutable int seedEdge = t.findRingSeedEdge(e.x, e.y, vp);
    bool consumed = t.onPlainLmbDown(e, vts);

    assert(consumed, "a plain-LMB press on an EDGE must be consumed — it grabs the edge");
    assert(!t.placeArmed_,
        "a press on an existing edge must NOT arm Place — that is the stray-vertex defect");
    assert(t.moveArmed_, "the press must arm a Move");
    assert(t.moveElem_ == MoveElem.Edge, "the grabbed element must be the EDGE, not a vertex");
    assert(t.grabbedVert_ < 0,
        "`grabbedVert` names a single grabbed VERTEX — an edge grab must leave it -1");
    assert(t.moveVerts_.length == 2, "an edge move drags exactly its two endpoints");
    assert(t.moveVerts_[0] == m.edges[seedEdge][0] && t.moveVerts_[1] == m.edges[seedEdge][1],
        "the moving set must be the picked edge's own endpoints");
    assert(t.moveBase_.length == 2
        && t.moveBase_[0] == m.vertices[t.moveVerts_[0]]
        && t.moveBase_[1] == m.vertices[t.moveVerts_[1]],
        "the arm must snapshot the endpoints' CURRENT positions as the drag's origin");
    assert(!t.moveDirty_, "arming alone must not count as a mutation");
    assert(m.vertices.length == vBefore && m.edges.length == eBefore
        && m.faces.length == fBefore, "the press itself must not mutate the mesh");

    // A release with no intervening motion is still a no-op: the targets land
    // back on the base positions (no background surface here, so every
    // re-snap misses and keeps its original), so nothing is written and no
    // undo entry is recorded. Consumed, because the gesture WAS armed.
    assert(t.lmbPlaceOrMoveUp(e, vts), "the release of an armed Move is consumed");
    assert(!t.moveArmed_ && t.moveElem_ == MoveElem.None, "the release must disarm");
    assert(m.vertices.length == vBefore && m.edges.length == eBefore
        && m.faces.length == fBefore, "a stationary edge grab must not mutate the mesh");
}

// ---------------------------------------------------------------------------
// The LIVE drag is ABSOLUTE, not incremental (task 0484, the compounding
// hazard). Every motion event recomputes its targets from `moveBase_` — the
// positions captured at ARM time — so N events at the same cursor position
// land the set in the same place as one, and a stream of events walking to a
// pixel lands it where a single event straight to that pixel would.
//
// If the targets were ever computed from the LIVE positions instead, each
// event would stack its delta onto the previous event's result and the
// element would race away from the cursor at a rate set by the event density
// — the classic bug this pins shut. Driven directly through the Vertex law
// (no background surface needed: `readHit` misses, so the target is the base
// position and the write is a no-op) plus a direct `perVertexTargetsFrom`
// comparison for the set law.
// ---------------------------------------------------------------------------
unittest {
    import mesh : makeGridPlane;
    import toolpipe.packets : SubjectPacket;

    auto t = new TopologyPenTool();
    Mesh m = makeGridPlane(3);
    t.meshSrc_ = () => &m;

    auto vp = makeGridPlaneTestViewport();
    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    // Arm an EDGE grab by hand (the pick itself is covered above).
    t.moveArmed_  = true;
    t.moveElem_   = MoveElem.Edge;
    t.moveVerts_  = [m.edges[0][0], m.edges[0][1]];
    t.moveBase_   = [m.vertices[t.moveVerts_[0]], m.vertices[t.moveVerts_[1]]];
    t.moveStartX_ = 100;
    t.moveStartY_ = 100;

    // The same cursor, asked twice, must answer twice the same — even after
    // the first answer has been written into the mesh.
    auto first = t.moveTargets(180, 140, vp, vts);
    t.applyMoveTargets(first);
    auto second = t.moveTargets(180, 140, vp, vts);
    assert(first.length == second.length, "target count must not depend on the live mesh");
    foreach (i, v; first)
        assert((v - second[i]).length < 1e-6f,
            "a repeated motion event must recompute the SAME target — targets are absolute, "
          ~ "computed from the arm-time base, never from the already-moved positions");

    // And the delta itself is measured from the PRESS pixel, not the previous
    // event's: the law is `perVertexTargetsFrom(base, cursor - press)`.
    auto direct = t.perVertexTargetsFrom(t.moveBase_, 180 - 100, 140 - 100, vp);
    foreach (i, v; direct)
        assert((v - first[i]).length < 1e-6f,
            "the set law must be the shared screen delta from the press pixel");
}

// ---------------------------------------------------------------------------
// The click-vs-drag gate on the SET law (task 0484): a press-and-release
// under `kMinDragPx` leaves the element exactly where it was. Without it a
// bare click would apply a ZERO delta — which is not a no-op, since each
// vertex would then re-snap to whatever background surface sits under its own
// pixel — and clicking an edge would yank it onto the background. Inherited
// with the law from Move Loop, whose `moveLoopUp` carries the same gate.
// ---------------------------------------------------------------------------
unittest {
    import mesh : makeGridPlane;
    import toolpipe.packets : SubjectPacket;

    auto t = new TopologyPenTool();
    Mesh m = makeGridPlane(3);
    t.meshSrc_ = () => &m;

    auto vp = makeGridPlaneTestViewport();
    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    t.moveArmed_  = true;
    t.moveElem_   = MoveElem.Edge;
    t.moveVerts_  = [m.edges[0][0], m.edges[0][1]];
    t.moveBase_   = [m.vertices[t.moveVerts_[0]], m.vertices[t.moveVerts_[1]]];
    t.moveStartX_ = 200;
    t.moveStartY_ = 200;

    // 2px away — inside the gate.
    auto held = t.moveTargets(201, 201, vp, vts);
    assert(held.length == 2);
    foreach (i, v; held)
        assert((v - t.moveBase_[i]).length < 1e-9f,
            "a sub-threshold drag must leave every vertex on its arm-time position");

    // 10px away — through the gate, so the law runs (and, with no background
    // surface in this fixture, every re-snap misses and keeps its original —
    // which is the documented miss policy, not the gate).
    t.moveStartX_ = 200; t.moveStartY_ = 200;
    auto moved = t.moveTargets(210, 200, vp, vts);
    assert(moved.length == 2, "past the gate the law still answers one target per vertex");
}

// The guard's CONTROL: Place must still arm on genuinely empty space. Same
// tool, same viewport, a mesh of two ISOLATED vertices (no edges, no faces)
// and a press ~70px clear of both — nothing for `overPrimaryEdgeOrFace` to
// find, so the press is a placement exactly as before. Without this, a guard
// that declined EVERY non-vertex press would look "fixed" while having killed
// Point mode's placement gesture. Runs in Point mode explicitly — the
// default Move mode DECLINES an empty-space press, which is the very
// distinction between the two modes (task 0483).
unittest {
    import toolpipe.packets : SubjectPacket;
    import std.math : hypot;

    auto t = new TopologyPenTool();
    Mesh m;
    m.addVertex(Vec3(-1, 0, -1));
    m.addVertex(Vec3( 1, 0,  1));
    t.meshSrc_ = () => &m;

    auto vp = makeGridPlaneTestViewport();
    ImVec2 p0;
    assert(TopologyPenTool.projectWorldPt(m.vertices[0], vp, p0), "setup: v0 must project");

    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    // A pixel 70px from v0 (and farther still from v1, which projects on the
    // opposite side of the grid) — clear of the press-pick reach.
    SDL_MouseButtonEvent e;
    e.x = cast(int)(p0.x + 70.0f); e.y = cast(int)p0.y;
    assert(t.findSourceVertex(e.x, e.y, vp) < 0,
        "setup: the probe pixel must resolve no vertex");
    assert(m.edges.length == 0, "setup: an isolated-vertex mesh must have no edges");

    t.penMode_ = PenMode.Point;
    assert(t.onPlainLmbDown(e, vts), "a press on empty space must still be consumed");
    assert(t.placeArmed_, "a press on empty space must still arm Place");
    assert(!t.moveArmed_, "a press on empty space must not arm Move");

    // ... and the SAME press in Move mode places nothing: Move has nothing to
    // move out there, and placing is Point's job (live-measured reference
    // split — toolcards/topology_pen/attr_defaults_capture.md, PRIVATE).
    t.resetAllGestureArms();
    t.penMode_ = PenMode.Move;
    assert(!t.onPlainLmbDown(e, vts), "Move mode must DECLINE a press on empty space");
    assert(!t.placeArmed_ && !t.moveArmed_, "Move mode must arm nothing on empty space");
}

// `toolStateJson().penMode` — the Mode dropdown's readback
// (doc/tasks/work/0482-topopen-move-nonvertex.md item 2): the wire tag, not
// the raw ordinal, and single-sourced from `penModeTable` so it tracks the
// `Param.intEnum_` schema and the `tool.attr mesh.topoPen mode <tag>` write.
unittest {
    import std.json : JSONType;

    auto t = new TopologyPenTool();

    auto s0 = t.toolStateJson();
    assert("penMode" in s0, "toolStateJson must publish penMode");
    assert(s0["penMode"].str == "move", "the default mode must report the \"move\" wire tag");

    // Every value round-trips through the SAME table the Param publishes, so
    // the readback cannot drift from the tag `tool.attr` accepts.
    static immutable string[8] tags =
        ["move", "duplicate", "remove", "split", "addLoop", "point", "fill", "smooth"];
    foreach (i, tag; tags) {
        t.penMode_ = cast(PenMode) i;
        assert(t.toolStateJson()["penMode"].str == tag,
            "mode " ~ tag ~ " must report its own wire tag");
    }

    // The two dropdown-adjacent flags are published alongside it (task 0483).
    t.penMode_ = PenMode.Move;
    auto s1 = t.toolStateJson();
    assert(s1["edgeLoop"].type == JSONType.false_ && s1["edgeSlide"].type == JSONType.false_,
        "both flags must start OFF in the readback");
    assert(s1["lmbAction"].str == "place_or_move",
        "a fresh tool must report the neutral LMB action");
    t.edgeLoop_ = t.edgeSlide_ = true;
    auto s2 = t.toolStateJson();
    assert(s2["edgeLoop"].type == JSONType.true_ && s2["edgeSlide"].type == JSONType.true_,
        "the readback must track the flags");

    // Keep Vertices (task 0494) is published too — it decides what a Remove
    // click destroys, so a run has to be able to read the branch back.
    assert(s1["keepVertex"].type == JSONType.false_,
        "keepVertex must read back OFF on a fresh tool — the measured default");
    t.keepVertex_ = true;
    assert(t.toolStateJson()["keepVertex"].type == JSONType.true_,
        "the readback must track keepVertex");
}

// ---------------------------------------------------------------------------
// Slide decline diagnostics — the two declines are DISTINGUISHABLE, and the
// record's lifecycle (doc/tasks/work/0482-topopen-move-nonvertex.md item 3
// follow-up). `makeGridPlane(3)` carries both shapes:
//   * edge 0-1 — a boundary edge whose endpoint 0 is a valence-2 corner, so
//     that rail resolves and the press ARMS (reason "none");
//   * edge 5-6 — an interior edge between two valence-4 vertices, so BOTH
//     endpoints hit the "2+ distinct continuation candidates" open case and the
//     press declines with NoContinuation, naming the seed;
//   * a pixel far from every edge declines with NoEdge and names nothing.
// The lifecycle assertions are the part an HTTP test cannot reach: the record
// must SURVIVE a later unrelated LEFT press (`resetAllGestureArms` runs before
// every one of them and must NOT erase it, or a consumer reading state after
// the fact sees "none") while `resyncSession` MUST clear it (its seed is an
// edge index an external history navigation can delete).
unittest {
    import mesh : makeGridPlane;
    import toolpipe.packets : SubjectPacket;

    auto t = new TopologyPenTool();
    Mesh m = makeGridPlane(3);
    t.meshSrc_ = () => &m;

    auto vp = makeGridPlaneTestViewport();

    ImVec2 pixOf(uint a, uint b) {
        ImVec2 pa, pb;
        assert(TopologyPenTool.projectWorldPt(m.vertices[a], vp, pa), "setup: endpoint must project");
        assert(TopologyPenTool.projectWorldPt(m.vertices[b], vp, pb), "setup: endpoint must project");
        return ImVec2((pa.x + pb.x) * 0.5f, (pa.y + pb.y) * 0.5f);
    }

    SubjectPacket subj;
    subj.mesh     = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    // Baseline: nothing pressed yet.
    assert(t.slideDecline_ == SlideDecline.None, "a fresh tool must record no decline");
    assert(t.slideDeclineSeed_ == -1, "a fresh tool must record no declined seed");

    // --- NoEdge: a pixel far off the grid entirely.
    SDL_MouseButtonEvent far;
    far.x = -5000; far.y = -5000;
    assert(!t.onCtrlLmbDown(far, vts), "a Ctrl+LMB press with no edge in range must decline");
    assert(t.slideDecline_ == SlideDecline.NoEdge,
        "a pick miss must be recorded as NoEdge");
    assert(t.slideDeclineSeed_ == -1, "a pick miss resolved no edge, so it names none");
    assert(!t.slideArmed_, "a pick miss must not arm Slide");

    // --- NoContinuation: the interior edge 5-6 (both endpoints valence-4).
    immutable uint kA = 5, kB = 6;
    immutable uint iEdge = m.edgeIndex(kA, kB);
    assert(iEdge != ~0u, "setup: grid edge 5-6 must exist");
    assert(TopologyPenTool.continuationNeighbor(&m, kA, kB) < 0
        && TopologyPenTool.continuationNeighbor(&m, kB, kA) < 0,
        "setup: edge 5-6 must be the both-endpoints-unresolved shape this case is about");

    auto ip = pixOf(kA, kB);
    SDL_MouseButtonEvent interior;
    interior.x = cast(int)ip.x; interior.y = cast(int)ip.y;
    assert(!t.onCtrlLmbDown(interior, vts),
        "the interior edge must still DECLINE (the shipped hold-fixed contract)");
    assert(t.slideDecline_ == SlideDecline.NoContinuation,
        "an edge that resolved but has no rail at either end must be NoContinuation, NOT NoEdge");
    assert(t.slideDeclineSeed_ == cast(int)iEdge,
        "the declined record must name the edge that WAS resolved");
    assert(!t.slideArmed_ && t.slideSeed_ == -1,
        "`slideSeed_` keeps its ARMED-gesture meaning and must stay -1 on a decline");

    // Lifecycle 1: a later unrelated LEFT press fires `resetAllGestureArms()`
    // via the dispatch reset hook, which must NOT erase this record.
    t.resetAllGestureArms();
    assert(t.slideDecline_ == SlideDecline.NoContinuation && t.slideDeclineSeed_ == cast(int)iEdge,
        "resetAllGestureArms must NOT clear the decline record — it runs before every LEFT "
      ~ "press, and erasing it there would hide the outcome a consumer is about to read");
    assert(!t.anyGestureArmed(),
        "the decline record must not register as an armed gesture (it would gate the hover "
      ~ "indicator)");

    // Lifecycle 2: an external history navigation MUST clear it — the seed is
    // an edge index the navigation can delete.
    t.resyncSession();
    assert(t.slideDecline_ == SlideDecline.None && t.slideDeclineSeed_ == -1,
        "resyncSession must clear the decline record rather than publish a stale edge index");

    // --- None: the boundary edge 0-1 arms (endpoint 0 is a valence-2 corner).
    assert(TopologyPenTool.continuationNeighbor(&m, 0, 1) >= 0,
        "setup: grid vertex 0 is a valence-2 corner, so its rail must resolve");
    auto bp = pixOf(0, 1);
    SDL_MouseButtonEvent boundary;
    boundary.x = cast(int)bp.x; boundary.y = cast(int)bp.y;
    assert(t.onCtrlLmbDown(boundary, vts), "a press with a resolvable rail must arm and consume");
    assert(t.slideArmed_, "the boundary-edge press must arm Slide");
    assert(t.slideDecline_ == SlideDecline.None && t.slideDeclineSeed_ == -1,
        "an ARMED press must record no decline (a stuck-at-NoEdge field would otherwise be "
      ~ "indistinguishable from a working one)");

    // Lifecycle 3: deactivate clears the record, so it cannot bleed into the
    // next activation (or, in a shared test process, the next test).
    t.slideDecline_     = SlideDecline.NoContinuation;
    t.slideDeclineSeed_ = cast(int)iEdge;
    t.deactivate();
    assert(t.slideDecline_ == SlideDecline.None && t.slideDeclineSeed_ == -1,
        "deactivate must clear the decline record");
}

// ---------------------------------------------------------------------------
// Task 0496 — the MEASURED PRESS-PICK reach, pinned at its BRACKET ENDS.
//
// This block is the pen-side pin of the press-pick query. It is written
// against the grid-plane viewport whose scale is hand-derivable (eye at y=5,
// fovY=90, 800x800 => 80 px per world unit, and `makeGridPlane`'s vertices sit
// on whole world units), so the probe pixels below land exactly where the
// comments say and the assertions do not round-trip through the code under
// test.
//
// WHAT IS PINNED, and what deliberately is NOT. The reference printed ONE
// press limit of 8.0, but the reach it delivered was only bracketed:
//
//     vertex : enumerated at 7.07px, not enumerated at 7.78px
//     edge   : enumerated at 7.00px, not enumerated at 8.85px
//
// So the probes are 7px (at/below both brackets' lower ends => must resolve)
// and 9px (above both brackets' upper ends => must not). Nothing here pins 8.0
// as a behavioural edge: the measurement does not locate the cut to better
// than a pixel, and a test that claimed otherwise would be inventing
// precision. The 8.0 VALUE is asserted at the end as the number we chose to
// carry, separately from the behaviour.
//
// FAILS ON THE SHIPPED BEHAVIOUR by construction: under the 15px gate this
// module carried until now, the 9px probes resolved the vertex and the edge.
// They are the near rim of the ~7px annulus in which our press disagreed with
// the reference's; the far rim (14px) is pinned by the annulus test below.
//
// Also pins the MEASURING POINT (task 0496's recorded, NOT-isolated
// divergence): both of these resolvers measure from the RAW CURSOR pixel,
// while `constraint.resolveHoverTarget` measures from the projected surface
// HIT. Unifying them is deferred (it changes what the pen resolves, not merely
// how far); this test makes our two origins explicit so neither can drift.
// ---------------------------------------------------------------------------
unittest {
    import mesh : makeGridPlane;
    import constraint : topoPenPressPickPx, topoPenSnapAcceptPx, topoPenSnapGatherPx;
    import std.math : hypot;

    auto t = new TopologyPenTool();
    Mesh m = makeGridPlane(2);          // 3x3 verts, 4 quads, 80px per cell here
    t.meshSrc_ = () => &m;

    auto vp = makeGridPlaneTestViewport();

    ImVec2 p0, p1;
    assert(TopologyPenTool.projectWorldPt(m.vertices[0], vp, p0), "setup: v0 must project");
    assert(TopologyPenTool.projectWorldPt(m.vertices[1], vp, p1), "setup: v1 must project");

    // --- vertex resolver, at both ends of the measured bracket ---
    immutable int inX  = cast(int)(p0.x + 7.0f), inY  = cast(int)p0.y;
    immutable int outX = cast(int)(p0.x + 9.0f), outY = cast(int)p0.y;
    // The probe distances are ASSERTED, not assumed: integer truncation of a
    // projected float could otherwise move a probe across the very bracket end
    // it is meant to sit on.
    assert(hypot(inX - p0.x, inY - p0.y) <= 7.07f,
        "setup: the near probe must sit at or inside the brackets' LOWER ends (7.07px / 7.00px)");
    assert(hypot(outX - p0.x, outY - p0.y) >= 8.85f,
        "setup: the far probe must sit at or beyond the brackets' UPPER ends (7.78px / 8.85px)");

    assert(t.findSourceVertex(inX, inY, vp) == 0,
        "a cursor 7px from a vertex is at the measured bracket's lower end and must resolve it");
    assert(t.findSourceVertex(outX, outY, vp) < 0,
        "a cursor 9px from every vertex is past the measured bracket and must resolve nothing "
      ~ "(the pre-fix 15px reach grabbed it — this is the annulus's near rim)");

    // --- edge resolver, same reach, no per-type threshold ---
    // PERPENDICULAR from edge 0-1's midpoint: 40px from either endpoint, and
    // the next parallel grid edge is 80px away, so edge 0-1 is unambiguous.
    ImVec2 mid = ImVec2((p0.x + p1.x) * 0.5f, (p0.y + p1.y) * 0.5f);
    immutable uint e01 = m.edgeIndex(0, 1);
    assert(e01 != uint.max, "setup: grid edge 0-1 must exist");
    assert(t.findRingSeedEdge(cast(int)mid.x, cast(int)(mid.y + 7.0f), vp) == cast(int)e01,
        "a cursor 7px from an edge segment is inside the same measured reach and must resolve it "
      ~ "— the press-pick reach is type-uniform");
    assert(t.findRingSeedEdge(cast(int)mid.x, cast(int)(mid.y + 9.0f), vp) < 0,
        "a cursor 9px from every edge segment is past the measured bracket "
      ~ "(the pre-fix 15px reach grabbed it)");

    // --- the reach is one value, not a per-type family: the SAME distance
    // decides for a vertex and for an edge. 7px in, 9px out, both types.
    assert((t.findSourceVertex(inX, inY, vp) >= 0)
        == (t.findRingSeedEdge(cast(int)mid.x, cast(int)(mid.y + 7.0f), vp) >= 0),
        "vertex and edge candidates must share ONE press-pick reach");
    assert((t.findSourceVertex(outX, outY, vp) >= 0)
        == (t.findRingSeedEdge(cast(int)mid.x, cast(int)(mid.y + 9.0f), vp) >= 0),
        "and they must fall out of it together too");

    // The values themselves, asserted LAST on purpose: the behaviour above is
    // the claim, and it must be what breaks if the reach moves. A value check
    // placed first would mask the behavioural probes it is meant to explain.
    assert(topoPenPressPickPx(vp) == 8.0f,
        "the press pick carries the one limit the reference printed, 8px at scale 1");
    // The drag-snap pair comes off the gesture's snap snapshot, which on a
    // freshly-constructed tool is the default configuration — so these still
    // pin the measured values, and they now pin them at their real source.
    assert(topoPenSnapAcceptPx(vp, t.dragSnap_) == 24.0f,
        "the drag-snap acceptance is a separate, wider radius — 24px at scale 1");
    assert(topoPenSnapGatherPx(vp, t.dragSnap_) == 40.0f,
        "and its gather is 40px, a ratio of 5/3 rather than the refuted 2x");
    assert(t.dragSnap_ == SnapPacket.init,
        "a pen that has seen no press runs on the default snap configuration, "
        ~ "which is what makes the pipeline-less paths behave as before");
}

// ---------------------------------------------------------------------------
// Task 0496 — THE ANNULUS. The single case that was divergent on main.
//
// Between the press-pick reach (~8px) and the 15px this tool shipped lies a
// ~7px annulus around every vertex and every edge in which our press took the
// element and the reference took the FACE underneath. Two of the reference's
// own cells sit squarely in it: a vertex at 14.0px and an edge at 9.0px, both
// of which produced no candidate of that type at all and resolved POLY.
//
// This test is that pair, at this module's own resolvers. Every probe here
// answered the OTHER way before this change — that is the point of the file.
//
// `pickPrimaryFace` needs `gpu_` and answers -1 under a bare `dub test`, so
// the "and the FACE wins instead" half cannot be asserted here; it is asserted
// through the HTTP path in tests/test_topopen_move_disambiguation.d, which has
// a real upload. What IS asserted here is the load-bearing half: the vertex
// and the edge are NOT candidates at those distances.
// ---------------------------------------------------------------------------
unittest {
    import mesh : makeGridPlane;
    import std.math : hypot;

    auto t = new TopologyPenTool();
    Mesh m = makeGridPlane(2);
    t.meshSrc_ = () => &m;

    auto vp = makeGridPlaneTestViewport();
    ImVec2 p0, p1;
    assert(TopologyPenTool.projectWorldPt(m.vertices[0], vp, p0), "setup: v0 must project");
    assert(TopologyPenTool.projectWorldPt(m.vertices[1], vp, p1), "setup: v1 must project");

    // --- the reference's own `P_vert14` cell: a vertex 14px away, nothing
    // else nearby. We grabbed it; the reference resolved the polygon.
    // The probe runs DIAGONALLY into the quad interior — 10px in each axis, so
    // 14.1px from v0 and 10px from each of the two grid edges leaving it. Both
    // of those are past the measured reach too, which is what makes this a
    // pure vertex-annulus probe rather than an edge grab in disguise.
    immutable int ax = cast(int)(p0.x + 10.0f), ay = cast(int)(p0.y + 10.0f);
    immutable float dV14 = hypot(ax - p0.x, ay - p0.y);
    assert(dV14 > 8.85f && dV14 < 20.0f,
        "setup: the probe must sit in the annulus — past the measured reach, well short of the "
      ~ "next vertex 80px along");
    assert(t.findRingSeedEdge(ax, ay, vp) < 0,
        "setup: no grid edge may be within the measured reach of the probe either, or this "
      ~ "would be an edge case wearing a vertex's clothes");
    assert(t.findSourceVertex(ax, ay, vp) < 0,
        "a press 14px from a vertex must NOT grab it: that is outside the measured press-pick "
      ~ "reach, and the reference resolved the polygon there. Before this fix our 15px gate "
      ~ "grabbed the vertex — a straight divergence, advertised by the hover highlight because "
      ~ "it shares this resolver");

    // --- the reference's own `P_edge9` cell: an edge 9px away.
    ImVec2 mid = ImVec2((p0.x + p1.x) * 0.5f, (p0.y + p1.y) * 0.5f);
    assert(t.findRingSeedEdge(cast(int)mid.x, cast(int)(mid.y + 9.0f), vp) < 0,
        "a press 9px from an edge must NOT grab it either — same annulus, same divergence");

    // --- and the hover highlight, which is the same answer by construction:
    // whatever `resolveGrabTarget` says is what the indicator paints, so the
    // annulus has to be closed on BOTH at once or the highlight lies.
    int idx = -12345;
    assert(t.resolveGrabTarget(ax, ay, vp, idx) == MoveElem.None,
        "the grab target 14px from a vertex must be None (no face term without gpu_) — the "
      ~ "highlight and the press must never name different elements");
    assert(idx < 0, "and it must publish no index");
}

// ---------------------------------------------------------------------------
// Task 0496 — Vertex > Edge > Face is MEASURED-POSITIVE. The OPPOSITE test.
//
// An earlier reading of the reference held that it takes ONE closest candidate
// across all types and applies the radius afterwards, which would make a
// vertex at 14px lose to an edge at 2px. Task 0496's `## Открыто` item №1 asked
// for a test pinning exactly that. The live run refuted it twice, on two
// independent cells: a vertex at 5.83px beat an edge at 3.00px AND a polygon at
// 0.00px, and a vertex at 7.07px beat an edge at 7.00px. Porting "one closest
// across types" would have been a regression, so this is the test that item
// asked for, INVERTED — and it is the guard against someone re-reading the old
// note and "fixing" the short circuit.
//
// Rig: `makeGridPlane(2)` down -Y, 80px per cell, so grid edge 0-1 is a
// horizontal screen segment from v0. The cursor sits 3px off that segment and
// 6.7px from v0 — the edge is strictly NEARER, both are inside the press-pick
// reach, and the VERTEX must win.
// ---------------------------------------------------------------------------
unittest {
    import mesh : makeGridPlane;
    import std.math : hypot;

    auto t = new TopologyPenTool();
    Mesh m = makeGridPlane(2);
    t.meshSrc_ = () => &m;

    auto vp = makeGridPlaneTestViewport();
    ImVec2 p0, p1;
    assert(TopologyPenTool.projectWorldPt(m.vertices[0], vp, p0), "setup: v0 must project");
    assert(TopologyPenTool.projectWorldPt(m.vertices[1], vp, p1), "setup: v1 must project");
    assert(p0.y == p1.y && p1.x > p0.x,
        "setup: grid edge 0-1 must be a horizontal screen segment running +x from v0");

    immutable int cx = cast(int)(p0.x + 6.0f), cy = cast(int)(p0.y + 3.0f);

    // The premise, measured on the fixture rather than assumed: the edge is
    // NEARER than the vertex, and both are inside the press-pick reach.
    immutable float dVert = hypot(cx - p0.x, cy - p0.y);
    assert(dVert > 3.0f && dVert <= 7.07f,
        "setup: the vertex must be FARTHER than the edge yet still inside the measured reach");
    immutable uint e01 = m.edgeIndex(0, 1);
    assert(e01 != uint.max, "setup: grid edge 0-1 must exist");
    assert(t.findRingSeedEdge(cx, cy, vp) == cast(int)e01,
        "setup: the nearest edge at this pixel must be 0-1, ~3px away");
    assert(t.findSourceVertex(cx, cy, vp) == 0,
        "setup: v0 must still be a candidate at this pixel");

    int idx = -12345;
    assert(t.resolveGrabTarget(cx, cy, vp, idx) == MoveElem.Vertex,
        "a vertex inside the press-pick reach must beat a strictly NEARER edge — 'one closest "
      ~ "candidate across types' was measured-negative and must not be ported");
    assert(idx == 0, "and the resolved element must be v0 itself");
}

// ---------------------------------------------------------------------------
// Task 0496 — the MEASURED snap-candidate set (`innerSnap`).
//
// Three separate claims, three separate pins:
//
//   1. The predicates. `isEdgeInterior` / `isVertexInterior` classify a grid
//      exactly as the measured law does (>= 2 incident polygons = interior).
//   2. The SNAP TARGET honours them. Split's target vertex C — vibe3d's only
//      "which existing element does this drag land on" query — refuses an
//      interior vertex at the default `innerSnap = false` and accepts it when
//      the flag is on. FAILS ON THE OLD BEHAVIOUR: before 0496 the same drag
//      split the quad regardless.
//   3. The press-time PICK is deliberately NOT gated, and wire geometry is
//      deliberately NOT excluded. Both are regression pins (green before and
//      after); they exist because both are decisions with a stated reason, and
//      a silent change to either would be a measured regression rather than an
//      improvement.
// ---------------------------------------------------------------------------
unittest {
    import mesh : makeGridPlane;

    Mesh m = makeGridPlane(2);   // 3x3 verts / 4 quads: vertex 4 is the interior one
    Mesh* mp = &m;

    // (1) the predicates
    immutable uint eInterior = m.edgeIndex(1, 4);   // center-touching: 2 polygons
    immutable uint eBorder   = m.edgeIndex(0, 1);   // perimeter: 1 polygon
    assert(eInterior != uint.max && eBorder != uint.max, "setup: both grid edges must exist");
    assert(isEdgeInterior(mp, eInterior),
        "an edge shared by two quads is interior");
    assert(!isEdgeInterior(mp, eBorder),
        "a perimeter edge has one polygon and is NOT interior");
    assert(isVertexInterior(mp, 4),
        "the grid's center vertex touches only interior edges");
    foreach (uint vi; [0u, 1u, 2u, 3u, 5u, 6u, 7u, 8u])
        assert(!isVertexInterior(mp, vi),
            "every perimeter vertex touches at least one border edge");

    // (3a) wire geometry stays a candidate — the named extrapolation boundary.
    Mesh w;
    w.addVertex(Vec3(0, 0, 0));            // isolated: no incident edges at all
    w.addVertex(Vec3(1, 0, 0));
    w.addVertex(Vec3(2, 0, 0));
    w.addEdge(1, 2);                       // bare wire edge: zero polygons
    w.buildLoops();
    Mesh* wp = &w;
    assert(!isVertexInterior(wp, 0),
        "an ISOLATED vertex is not interior — the measured predicate is about the interior, and "
      ~ "face-less geometry is outside its domain (see the filter's own note)");
    assert(!isVertexInterior(wp, 1),
        "a wire-edge endpoint is not interior either");
    immutable uint wireEdge = w.edgeIndex(1, 2);
    assert(wireEdge != uint.max, "setup: the wire edge must exist");
    assert(!isEdgeInterior(wp, wireEdge),
        "a zero-polygon wire edge is not interior");
}

// ---------------------------------------------------------------------------
// Task 0523 — the GUIDE now owns that rule, and owns exactly that rule.
//
// The border-only filter moved off a `bool` parameter and onto the object the
// pen registers with the snapping service. This block pins the move as an
// EQUALITY against the predicate the old parameter used, vertex by vertex, so
// "the rule went somewhere else" cannot quietly become "the rule changed":
// `admits` is the only copy now, and it has to answer what the scan answered.
//
// Then the three refusals the parameter never had to make, because a private
// vertex scan can only ever be offered vertices of the mesh it is scanning,
// and the service's walk can offer anything it enumerates.
// ---------------------------------------------------------------------------
unittest {
    import mesh : makeGridPlane;

    Mesh m = makeGridPlane(2);   // 3x3 verts / 4 quads; vertex 4 is the interior one
    Mesh* mp = &m;

    auto g = new PenSnapGuide();
    g.retarget(mp, false);       // innerSnap off — the measured default

    // (1) EQUALITY with the predicate, over every vertex. Not "the interior one
    // is refused" — every vertex, so a rule that drifted on any single one of
    // them fails here rather than in a fixture six months later.
    foreach (vi; 0 .. m.vertices.length)
        assert(g.admits(SnapType.Vertex, cast(int)vi, 0)
                 == !isVertexInterior(mp, cast(uint)vi),
            "the guide's admission rule must BE the border predicate, vertex for vertex");
    assert(!g.admits(SnapType.Vertex, 4, 0),
        "and concretely: the grid's interior vertex is refused at innerSnap = false");

    // (2) innerSnap opens the interior, and opens it for everything.
    g.retarget(mp, true);
    foreach (vi; 0 .. m.vertices.length)
        assert(g.admits(SnapType.Vertex, cast(int)vi, 0),
            "innerSnap on: every vertex of the mesh is a candidate");

    // (3) the three refusals a scan never had to make.
    g.retarget(mp, true);        // deliberately the PERMISSIVE setting, so what
                                 // follows is the type/slot/range rule alone and
                                 // not the border rule answering for it.
    assert(!g.admits(SnapType.Edge, 0, 0) && !g.admits(SnapType.EdgeCenter, 0, 0)
        && !g.admits(SnapType.Polygon, 0, 0) && !g.admits(SnapType.PolyCenter, 0, 0)
        && !g.admits(SnapType.Grid, -1, 0) && !g.admits(SnapType.Workplane, -1, 0),
        "the pen's snap target is a VERTEX by definition — every other enumerated type is "
      ~ "refused outright, never merely outranked");
    assert(!g.admits(SnapType.Vertex, 4, 1),
        "a BACKGROUND source is a placement reference, never a weld target: the pen cannot "
      ~ "edit that mesh, so its vertices are not candidates");
    assert(!g.admits(SnapType.Vertex, cast(int)m.vertices.length, 0)
        && !g.admits(SnapType.Vertex, -1, 0),
        "an index outside the mesh is refused rather than read");

    // (4) no mesh at all — a guide the tool has not pointed anywhere yet.
    auto blank = new PenSnapGuide();
    assert(!blank.admits(SnapType.Vertex, 0, 0),
        "a guide with no mesh admits nothing; it must not answer from a null");

    // (5) and the tool must be able to reach that state without faulting: a
    // press on a tool whose mesh source is not bound yet still registers a
    // guide, and registering aims it at the mesh. `mesh` CALLS the delegate.
    auto bare = new TopologyPenTool();
    bare.registerSnapGuide();
    assert(bare.snapGuide_ !is null && !bare.snapGuide_.admits(SnapType.Vertex, 0, 0),
        "a press with no mesh source bound must register a guide that admits nothing, "
      ~ "not fault on a null delegate");
    bare.unregisterSnapGuide();   // and the mirror must be safe with no pipeline
}

// ---------------------------------------------------------------------------
// Task 0538 — `backFace`: the ORIENTATION half of the pen's admission rule.
//
// MEASURED: at the default (OFF) a candidate whose own normal points away from
// the viewer is refused; at ON the orientation test is not run at all. The
// normal is the candidate's own — the uniform average of its incident face
// normals — and the reject is a strict `dot > 0` against the ONE screen ray of
// the query, so a zero normal survives.
//
// The rig is one quad, driven from BOTH sides of itself, so each claim is a
// pair of cells that differ in exactly one thing. Nothing here reads a
// hand-computed pixel: the aim is the candidate's own projection.
//
// FAILS ON THE OLD BEHAVIOUR: before this task the pen's snap admission had no
// orientation test at all — i.e. it shipped the ON branch while the measured
// default is OFF — so every "refused" assertion below was an "admitted".
// ---------------------------------------------------------------------------
unittest {
    // One quad on the XZ plane wound to a +Y normal (`[0,3,2,1]`; the
    // `[0,1,2,3]` order gives -Y — see `makeGridPlaneFrontViewport`).
    Mesh m;
    m.addVertex(Vec3(-1, 0, -1));
    m.addVertex(Vec3( 1, 0, -1));
    m.addVertex(Vec3( 1, 0,  1));
    m.addVertex(Vec3(-1, 0,  1));
    m.addFace([0u, 3u, 2u, 1u]);
    m.buildLoops();
    Mesh* mp = &m;
    assert(m.faceNormal(0).y > 0.9f,
        "setup: the quad must face +Y, or the two cameras below are not on the sides "
      ~ "this case names");

    Viewport above = makeGridPlaneTestViewport();       // eye +Y — the FRONT here
    Viewport below = makeGridPlaneFrontViewport();      // eye -Y — the BACK here

    auto g = new PenSnapGuide();

    // (1) The law, both directions, at the measured default. Every vertex of
    // this quad is a border vertex, so the border half admits all four and
    // whatever difference the two cells show is the orientation half's.
    g.retarget(mp, /*innerSnap*/false);                 // backFace defaults OFF
    foreach (vi; 0 .. m.vertices.length) {
        g.aimAt(above, cast(int)projectedX(mp, cast(uint)vi, above),
                       cast(int)projectedY(mp, cast(uint)vi, above));
        assert(g.admits(SnapType.Vertex, cast(int)vi, 0),
            "a FRONT-facing vertex is admitted at the measured default");
        g.aimAt(below, cast(int)projectedX(mp, cast(uint)vi, below),
                       cast(int)projectedY(mp, cast(uint)vi, below));
        assert(!g.admits(SnapType.Vertex, cast(int)vi, 0),
            "and the very same vertex, seen from the other side, is REFUSED — this is the "
          ~ "whole of what `backFace` at its default does");
    }

    // (2) `backFace` ON skips the test: the back-facing cell now admits, and
    // the front-facing one is unchanged (the flag OPENS, it never closes).
    g.retarget(mp, /*innerSnap*/false, /*backFace*/true);
    foreach (vi; 0 .. m.vertices.length) {
        g.aimAt(below, cast(int)projectedX(mp, cast(uint)vi, below),
                       cast(int)projectedY(mp, cast(uint)vi, below));
        assert(g.admits(SnapType.Vertex, cast(int)vi, 0),
            "backFace ON admits the back side");
        g.aimAt(above, cast(int)projectedX(mp, cast(uint)vi, above),
                       cast(int)projectedY(mp, cast(uint)vi, above));
        assert(g.admits(SnapType.Vertex, cast(int)vi, 0),
            "and still admits the front side — the flag opens a set, it does not swap one");
    }

    // (3) The two halves are INDEPENDENT: `backFace` must not smuggle the
    // interior open. A 3x3 grid seen from its own front, with backFace ON and
    // innerSnap at its default, still refuses the interior vertex.
    {
        import mesh : makeGridPlane;
        Mesh grid = makeGridPlane(2);
        Mesh* gp  = &grid;
        Viewport front = makeGridPlaneFrontViewport();
        auto g2 = new PenSnapGuide();
        g2.retarget(gp, /*innerSnap*/false, /*backFace*/true);
        g2.aimAt(front, cast(int)projectedX(gp, 4, front), cast(int)projectedY(gp, 4, front));
        assert(!g2.admits(SnapType.Vertex, 4, 0),
            "backFace opens the ORIENTATION, never the topology — the interior vertex stays "
          ~ "refused while innerSnap is off");
        g2.retarget(gp, /*innerSnap*/true, /*backFace*/false);
        assert(g2.admits(SnapType.Vertex, 4, 0),
            "and the converse: innerSnap opens the interior of a FRONT-facing mesh without "
          ~ "needing backFace at all");
    }

    // (4) A ZERO normal is never rejected — the reference's own clause, and
    // ours by the same strict `> 0`. Wire geometry has no incident face, so its
    // accumulated normal is exactly zero from every camera.
    {
        Mesh w;
        w.addVertex(Vec3(0, 0, 0));
        w.addVertex(Vec3(1, 0, 0));
        w.addEdge(0, 1);
        w.buildLoops();
        Mesh* wp = &w;
        auto g3 = new PenSnapGuide();
        g3.retarget(wp, /*innerSnap*/false);            // backFace at its default
        foreach (ref Viewport cam; [above, below]) {
            g3.aimAt(cam, cast(int)projectedX(wp, 0, cam), cast(int)projectedY(wp, 0, cam));
            assert(g3.admits(SnapType.Vertex, 0, 0),
                "a vertex with no incident face has a zero normal, and a zero normal is not "
              ~ "back-facing from anywhere");
        }
    }

    // (5) The UN-AIMED case, which is OURS and not the reference's (it has no
    // such state). The test is skipped rather than inverted into a rejection —
    // pinned because "an unaimed guide silently rejects everything" would be a
    // policy nobody measured, and would be indistinguishable from a bug.
    auto g4 = new PenSnapGuide();
    g4.retarget(mp, /*innerSnap*/false);
    assert(!g4.isAimed(), "setup: a fresh guide is not aimed");
    foreach (vi; 0 .. m.vertices.length)
        assert(g4.admits(SnapType.Vertex, cast(int)vi, 0),
            "an un-aimed guide has no ray to test against, so the orientation half does not "
          ~ "run — the border half still answers on its own");
}

// ---------------------------------------------------------------------------
// Task 0538 — the attribute reaches the guide through the REAL registration,
// and it is sticky.
//
// The field, the Param and `/api/tool/state` are one thing; that a press
// carries the CURRENT value of the flag into the object the service holds is
// another, and it is the one a user notices. Driven through
// `registerSnapGuide`, the same call the press makes.
// ---------------------------------------------------------------------------
unittest {
    Mesh m;
    m.addVertex(Vec3(-1, 0, -1));
    m.addVertex(Vec3( 1, 0, -1));
    m.addVertex(Vec3( 1, 0,  1));
    m.addVertex(Vec3(-1, 0,  1));
    m.addFace([0u, 3u, 2u, 1u]);          // +Y normal
    m.buildLoops();
    Mesh* mp = &m;

    Viewport back = makeGridPlaneFrontViewport();   // eye -Y: this quad's BACK

    auto t = new TopologyPenTool();
    t.meshSrc_ = () => mp;

    assert(!t.backFace_, "a fresh tool must start at the measured default, OFF");

    t.registerSnapGuide();
    auto g = t.snapGuide_;
    g.aimAt(back, cast(int)projectedX(mp, 0, back), cast(int)projectedY(mp, 0, back));
    assert(!g.admits(SnapType.Vertex, 0, 0),
        "with the tool's flag at its default the registered guide refuses the back side");

    t.backFace_ = true;
    t.registerSnapGuide();               // the same object, re-pointed
    assert(t.snapGuide_ is g, "the tool keeps ONE guide and re-points it; the registration is "
                            ~ "what is per-gesture");
    g.aimAt(back, cast(int)projectedX(mp, 0, back), cast(int)projectedY(mp, 0, back));
    assert(g.admits(SnapType.Vertex, 0, 0),
        "and a press taken with the flag ON carries it into the guide — a value that never "
      ~ "reaches the admission rule is a dead toggle");

    t.resyncSession();
    assert(t.backFace_,
        "sticky across resyncSession(), like every other dropdown-adjacent option on this tool");
}

// ---------------------------------------------------------------------------
// Task 0523 — the guide's border classification follows the mesh it guards.
//
// The scan this replaces recounted the whole mesh on every call, so staleness
// was impossible by construction. The guide caches the counts, and its
// registration spans a whole gesture — and one of the pen's gestures (Move)
// writes the mesh on every motion event. The cache key is what makes those two
// facts compatible, and this is its pin: the SAME guide, the SAME vertex, a
// different answer once the topology under it changes.
// ---------------------------------------------------------------------------
unittest {
    import mesh : makeGridPlane;

    Mesh m = makeGridPlane(2);
    Mesh* mp = &m;

    auto g = new PenSnapGuide();
    g.retarget(mp, false);
    assert(!g.admits(SnapType.Vertex, 4, 0),
        "setup: vertex 4 is interior to the intact grid and must be refused");

    // Delete one of the four quads. Vertex 4 now touches a border edge, so the
    // very same query must start admitting it.
    bool[] drop = new bool[](m.faces.length);
    drop[0] = true;
    assert(m.deleteFacesByMask(drop, true, true) == 1, "setup: one quad must have gone");
    assert(!isVertexInterior(mp, 4),
        "setup: with a quad gone the centre vertex touches a border edge");
    assert(g.admits(SnapType.Vertex, 4, 0),
        "FAILS ON A STALE CACHE: the guide must re-derive its border counts when the mesh "
      ~ "it guards is edited under it — the pen's Move gesture does exactly that, mid-gesture");
}

// ---------------------------------------------------------------------------
// Task 0523 — the guide as the snapping service sees it.
//
// `admits` is the pen's own channel; `proximity` is the service's, and the two
// must be one rule wearing two shapes. Also the values that are MEASURED and
// must not drift: priority 2, and no flags at all.
// ---------------------------------------------------------------------------
unittest {
    import mesh : makeGridPlane;

    Mesh m = makeGridPlane(2);
    Mesh* mp = &m;
    // The FRONT camera: this block AIMS the guide, and an aimed guide runs the
    // orientation test (task 0538). The grid's quads face -Y, so from the +Y
    // camera every candidate here would be refused for being back-facing and
    // the priority/distance assertions below would never be reached.
    Viewport vp = makeGridPlaneFrontViewport();

    auto g = new PenSnapGuide();
    g.retarget(mp, false);

    float d;
    // Seeded exactly as the arbitration seeds it, so what the assertions below
    // observe is the pen ANSWERING 2 and not the pen staying silent while a
    // default happens to be near it.
    int   prio = kGuidePrioritySeed;

    // Un-aimed: a guide that has never been told where the cursor is cannot
    // answer a distance, and answering one anyway would be indistinguishable
    // from a near miss.
    assert(!g.isAimed(), "a fresh guide is not aimed");
    assert(!g.proximity(m.vertices[0], SnapType.Vertex, 0, 0, d, prio),
        "an un-aimed guide must REJECT rather than measure against a zero viewport");

    immutable int cx = cast(int)projectedX(mp, 0, vp);
    immutable int cy = cast(int)projectedY(mp, 0, vp);
    g.aimAt(vp, cx, cy);

    // The rule is the same rule: whatever `admits` refuses, `proximity` refuses.
    foreach (vi; 0 .. m.vertices.length) {
        float dd; int pp;
        assert(g.proximity(m.vertices[vi], SnapType.Vertex, cast(int)vi, 0, dd, pp)
                 == g.admits(SnapType.Vertex, cast(int)vi, 0),
            "proximity and admits are one rule — the service's channel and the tool's own "
          ~ "must never disagree about a candidate");
    }

    // The distance is the candidate's own screen distance from the aim, which
    // is what makes the service's ranking mean anything.
    assert(g.proximity(m.vertices[0], SnapType.Vertex, 0, 0, d, prio),
        "vertex 0 is a border vertex and is admitted");
    assert(d < 1.0f,
        "the candidate under the aim reports ~0 px; it is a screen distance, not a world one");
    float dFar; int prioFar = kGuidePrioritySeed;
    assert(g.proximity(m.vertices[2], SnapType.Vertex, 2, 0, dFar, prioFar),
        "the far corner is a border vertex too");
    assert(dFar > d, "and it must rank farther — the ordering is the aim's, not the index's");

    // MEASURED, both of them. See PenSnapGuide's block comment before moving
    // either: 2 is the reference's own declared priority for this guide (one
    // above the framework's pre-seeded default, one below the element snap's),
    // and its flags accessor is absent entirely — in particular it does NOT
    // claim "run even when the global snap enable is off".
    assert(prio == PenSnapGuide.kPriority && prio == 2,
        "the pen's guide declares priority 2");
    assert(prioFar == 2, "and it declares it for every candidate, not just the winner");
    assert(g.flags() == 0,
        "the pen's guide declares NO flags — the reference installs no accessor at all, and "
      ~ "the missing 'always-on' bit is the whole reason the weld is gated");

    // The draw protocol has a producer and no consumer yet; pin that the guide
    // at least records what it was told, so a renderer has something to read.
    assert(g.drawState() == GuideDrawState.Off, "a guide starts undrawn");
    g.setDrawState(GuideDrawState.Chosen);
    assert(g.drawState() == GuideDrawState.Chosen, "and records the state pushed into it");
}

// ---------------------------------------------------------------------------
// Task 0523 — the REGISTRATION, through the real press/release dispatch.
//
// MEASURED lifecycle: the reference's pen adds its guide to the shared
// event-translation packet when the drag starts and removes it on mouse-up,
// re-adding the same object on every intervening move (the registry dedups).
// This drives our own press and release and watches the service's registry.
//
// The registry is on the live `SnapStage`, reached through the pipeline
// global, so this block installs a pipeline and restores whatever was there.
// ---------------------------------------------------------------------------
unittest {
    import view     : View;
    import editmode : EditMode;
    import mesh     : makeGridPlane;
    import toolpipe.packets  : SubjectPacket;
    import toolpipe.pipeline : ToolPipeContext;

    loadSDL();
    SDL_SetModState(cast(SDL_Keymod)0);

    auto saved = g_pipeCtx;
    scope(exit) g_pipeCtx = saved;   // restore, never force-null: this global is
                                     // process-wide and shared with every other
                                     // unittest in the binary.

    auto ctx = new ToolPipeContext();
    auto st  = new SnapStage();
    ctx.pipeline.add(st);
    g_pipeCtx = ctx;

    Mesh m = makeGridPlane(2);
    Mesh* mp = &m;
    auto t       = new TopologyPenTool();
    auto view    = new View(0, 0, 100, 100);
    auto history = new CommandHistory();
    t.meshSrc_          = () => mp;
    t.history_          = history;
    t.splitEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                   "mesh.topoPen_split", "Topology Split",
                                                   MeshEditScope.Geometry);
    Viewport vp = makeGridPlaneTestViewport();
    SubjectPacket subj;
    subj.mesh     = mp;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    assert(st.guideCount == 0, "setup: the service's registry starts empty");

    SDL_MouseButtonEvent down;
    down.button = SDL_BUTTON_MIDDLE;
    down.x = cast(int)projectedX(mp, 0, vp);
    down.y = cast(int)projectedY(mp, 0, vp);
    assert(t.onMouseButtonDown(down, vts), "a plain-MMB press on a vertex must consume");
    assert(st.guideCount == 1, "the press must have registered the pen's guide");
    assert(st.guides[0] is t.snapGuide_, "and it must be the pen's own object");

    // The ranges are pushed IN at registration — the guide does not source
    // them. This is the direction that is measured, and the value is the
    // stage's, not a constant the pen carries.
    assert(t.snapGuide_.innerPushedPx() == st.innerRangePx
        && t.snapGuide_.outerPushedPx() == st.outerRangePx,
        "the service pushes its ranges into the guide at registration");

    // A second press without a release (a malformed sequence, and the shape of
    // the reference's own re-add on every move) must not register twice.
    assert(t.onMouseButtonDown(down, vts), "a second press is still consumed");
    assert(st.guideCount == 1, "re-registering the same guide is a no-op, not a second vote");

    SDL_MouseButtonEvent up;
    up.button = SDL_BUTTON_MIDDLE;
    up.x = cast(int)projectedX(mp, 2, vp);
    up.y = cast(int)projectedY(mp, 2, vp);
    assert(t.onMouseButtonUp(up, vts), "a plain-MMB release must consume");
    assert(st.guideCount == 0, "the release must have removed it");

    // A tool switch mid-gesture ends the gesture the same way. Re-arm, then
    // deactivate without ever releasing.
    assert(t.onMouseButtonDown(down, vts), "re-arm for the deactivate case");
    assert(st.guideCount == 1, "setup: registered again");
    t.deactivate();
    assert(st.guideCount == 0,
        "a tool switch mid-drag must not leave a guide in the service's registry, still "
      ~ "admitting for a mesh nobody is editing");

    SDL_SetModState(cast(SDL_Keymod)0);
}

// ---------------------------------------------------------------------------
// STARTUP SNAP ARMING — activating this tool opens the weld gate, and dropping
// it hands the global back.
//
// MEASURED: every one of the twelve shipped UI routes to the reference's pen
// passes "snap state at startup" on the activation command, which pushes the
// previous app-global snap state and writes the new one; the drop restores it.
// Three negative controls establish the attribution is the INVOCATION and not
// the preset or the composition — see `armStartupSnap` for them.
//
// What this block pins, in the order it matters:
//
//   1. ACTIVATION ARMS. The gate `resolveSnapTargetVert` reads is open with no
//      setting touched by the user. This is the user-visible change.
//   2. THE DROP RESTORES, both polarities. Off-before stays off-after; a user
//      who had snapping ON keeps it ON. A restore that wrote a constant would
//      silently switch snapping off for that user every time they touched the
//      pen.
//   3. NO PIPELINE, NO CRASH. Every direct-construction rig in this file, and
//      every headless path, activates with no SNAP stage to arm.
//   4. A SCENE RESET WINS. `reset()` runs BEFORE the tool drop it triggers, so
//      the drop's restore must not resurrect the pre-reset value. This is the
//      cross-test-bleed shape: one test arms the pen, the next `/api/reset`s
//      and inherits snapping still on.
// ---------------------------------------------------------------------------
unittest {
    import toolpipe.pipeline : ToolPipeContext;

    auto saved = g_pipeCtx;
    scope(exit) g_pipeCtx = saved;   // process-wide global — restore, never null

    auto ctx = new ToolPipeContext();
    auto st  = new SnapStage();
    ctx.pipeline.add(st);
    g_pipeCtx = ctx;

    // --- 1 + 2a. arm from OFF, restore to OFF ------------------------------
    {
        assert(!st.enabled, "setup: the stage still SHIPS snapping off");
        auto t = new TopologyPenTool();
        t.activate();
        assert(st.enabled,
            "activating the pen must arm the application-wide snap enable — "
            ~ "this IS the weld gate, and it is what every shipped route to "
            ~ "the reference's pen does");
        t.deactivate();
        assert(!st.enabled,
            "dropping the pen must hand back the value it was given, not "
            ~ "leave a global permanently flipped by having touched a tool");
    }

    // --- 2b. arm from ON, restore to ON ------------------------------------
    {
        st.enabled = true;                       // the user turned snapping on
        auto t = new TopologyPenTool();
        t.activate();
        assert(st.enabled);
        t.deactivate();
        assert(st.enabled,
            "a user who already had snapping ON must still have it ON after "
            ~ "the pen is dropped — the restore writes the SAVED value");
        st.enabled = false;
    }

    // --- 3. no SNAP stage in the pipeline, and no pipeline at all ----------
    {
        auto bare = new ToolPipeContext();       // pipeline with no SNAP stage
        g_pipeCtx = bare;
        auto t = new TopologyPenTool();
        t.activate();
        t.deactivate();                          // must not throw / fault

        g_pipeCtx = null;                        // no pipeline at all
        auto t2 = new TopologyPenTool();
        t2.activate();
        t2.deactivate();
        g_pipeCtx = ctx;
    }

    // --- 4. a scene reset between activate and drop wins -------------------
    {
        st.enabled = true;                       // user had snapping on ...
        auto t = new TopologyPenTool();
        t.activate();                            // ... pen arms over it
        st.reset();                              // /api/reset — clean slate
        assert(!st.enabled, "setup: reset() lands on the shipped default");
        t.deactivate();                          // the drop the reset triggers
        assert(!st.enabled,
            "the tool drop that a scene reset triggers must NOT resurrect the "
            ~ "pre-reset snap state — that is snapping left armed across a "
            ~ "reset, bleeding into whatever runs next in the same process");
    }
}

// ---------------------------------------------------------------------------
// Task 0502 — the predicate above on a NON-MANIFOLD edge.
//
// The grid fixture cannot see this: there, "count off the faces" and "walk the
// half-edge rings" agree on every edge, so a green grid test says nothing about
// which one is under the predicate. Three quads sharing edge 0-1 separate them
// — the rings yield ONE face (they have no representation for the fan), the
// face scan yields three.
//
// The consequence was not academic. `isEdgeInterior` IS the border-only
// snap-candidate filter (`findRingSeedEdge`/`findSourceVertex` with
// `innerSnap` off), so a non-manifold edge — the most topologically suspect
// edge in the mesh — read as a plain border edge and was offered as a snap
// target, along with both its endpoints.
// ---------------------------------------------------------------------------
unittest {
    Mesh m;
    foreach (p; [Vec3(0,0,0), Vec3(1,0,0), Vec3(0,1,0), Vec3(1,1,0),
                 Vec3(0,0,1), Vec3(1,0,1), Vec3(0,-1,0), Vec3(1,-1,0)])
        m.addVertex(p);
    m.addFace([0u, 1u, 3u, 2u]);
    m.addFace([0u, 1u, 5u, 4u]);
    m.addFace([0u, 1u, 7u, 6u]);
    m.buildLoops();
    Mesh* mp = &m;

    immutable uint fan = m.edgeIndex(0, 1);
    assert(m.edgePolygonCounts()[fan] == 3, "setup: three quads really do border it");
    assert(isEdgeInterior(mp, fan),
        "FAILS ON THE OLD BEHAVIOUR: the ring walk returned ONE face here, so a "
      ~ "non-manifold edge classified as a BORDER edge and entered the "
      ~ "border-only snap-candidate set");
    assert(isVertexInterior(mp, 0) == false,
        "vertex 0 still touches genuine border edges, so it is not interior — the "
      ~ "fix must not flip this by over-counting");

    // The array overload the two scans hoist is the same predicate, not a
    // second one that could drift.
    auto counts = m.edgePolygonCounts();
    foreach (uint ei; 0 .. cast(uint)m.edges.length)
        assert(isEdgeInterior(counts, ei)
            == isEdgeInterior(mp, ei),
            "the hoisted overload and the one-off overload must agree edge for edge");
}

// ---------------------------------------------------------------------------
// Task 0496, claim (2) + claim (3b): the Split snap target through the REAL
// dispatch path, and the press-time pick left alone.
//
// Rig: `makeGridPlane(2)` (3x3 verts / 4 quads) looked at down -Y. A plain-MMB
// press on corner vertex 0 arms Split; the release lands on the grid's INTERIOR
// center vertex 4, which shares quad (0,1,4,3) with it — so before 0496 this
// drag chord-split that quad. With `innerSnap` at its measured default the
// target is not a candidate and the release is a clean no-op; with `innerSnap`
// on, the same drag splits again.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import mesh : makeGridPlane;
    import toolpipe.packets : SubjectPacket;

    loadSDL();
    SDL_SetModState(cast(SDL_Keymod)0);

    static struct Rig {
        TopologyPenTool t;
        Mesh* m;
        Viewport vp;
        VectorStack vts;
        SubjectPacket* subj;
    }

    // A fresh tool + mesh per case: Split MUTATES on success, so the two cases
    // cannot share a rig without the first one's cut changing the second's
    // topology (and its vertex indices).
    static Rig makeRig(bool innerSnap, Mesh* m) {
        auto t       = new TopologyPenTool();
        auto view    = new View(0, 0, 100, 100);
        auto history = new CommandHistory();
        *m = makeGridPlane(2);
        t.meshSrc_          = () => m;
        t.history_          = history;
        t.innerSnap_        = innerSnap;
        t.splitEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                       "mesh.topoPen_split", "Topology Split",
                                                       MeshEditScope.Geometry);
        Rig r;
        r.t    = t;
        r.m    = m;
        // The FRONT camera (task 0538): the grid's quads face -Y, and this
        // case's innerSnap-off leg expects a NO-OP. From the +Y camera that
        // no-op would arrive through the `backFace` gate instead of through
        // the border rule, i.e. it would pass while testing nothing — the
        // same argument this rig already makes for keeping snapping on.
        r.vp   = makeGridPlaneFrontViewport();
        r.subj = new SubjectPacket();
        r.subj.mesh     = m;
        r.subj.viewport = r.vp;
        r.vts.put(r.subj);
        // Task 0523: BOTH cases run with snapping on, including the one that
        // expects a no-op. The subject here is the ADMISSION rule, and a rig
        // with snapping off would reach the same no-op through the master
        // gate — the interior vertex would never be judged, and the case
        // would pass without exercising what it names.
        r.vts.put(penTestSnapOn());
        return r;
    }

    static void driveSplit(ref Rig r, uint fromVert, uint toVert) {
        ImVec2 pa, pb;
        assert(TopologyPenTool.projectWorldPt(r.m.vertices[fromVert], r.vp, pa),
            "setup: the source vertex must project");
        assert(TopologyPenTool.projectWorldPt(r.m.vertices[toVert], r.vp, pb),
            "setup: the target vertex must project");
        SDL_MouseButtonEvent down;
        down.button = SDL_BUTTON_MIDDLE;
        down.x = cast(int)pa.x; down.y = cast(int)pa.y;
        assert(r.t.onMouseButtonDown(down, r.vts), "a plain-MMB press on a vertex must consume");
        assert(r.t.splitArmed_, "a plain-MMB press on a vertex must arm Split");
        assert(r.t.splitSourceVert_ == cast(int)fromVert,
            "the press must arm the PRESSED vertex as the split source — the press-time pick is "
          ~ "NOT candidate-filtered, whatever innerSnap says");
        SDL_MouseButtonEvent up;
        up.button = SDL_BUTTON_MIDDLE;
        up.x = cast(int)pb.x; up.y = cast(int)pb.y;
        assert(r.t.onMouseButtonUp(up, r.vts), "a plain-MMB release must consume");
        assert(!r.t.splitArmed_, "the release must disarm Split whatever the outcome");
    }

    // --- default (innerSnap == false): the interior target is not a candidate.
    Mesh mOff;
    auto off = makeRig(false, &mOff);
    assert(isVertexInterior(&mOff, 4),
        "setup: the grid's center vertex must be interior, or this case tests nothing");
    immutable size_t fBefore = mOff.faces.length;
    immutable size_t eBefore = mOff.edges.length;

    // The CLAIM first, end to end through the real dispatch, so it is the
    // assertion that breaks if the gate goes away.
    driveSplit(off, 0, 4);
    assert(mOff.faces.length == fBefore && mOff.edges.length == eBefore,
        "a Split whose target vertex is INTERIOR must be a clean no-op at the measured default "
      ~ "(before task 0496 this chord-split the quad)");

    // Then WHY: the press-time pick still sees that interior vertex — only the
    // SNAP TARGET is filtered (claim 3b).
    assert(off.t.findSourceVertex(cast(int)projectedX(&mOff, 4, off.vp),
                                 cast(int)projectedY(&mOff, 4, off.vp), off.vp) == 4,
        "the press-time pick must still resolve an INTERIOR vertex — the captures we hold show "
      ~ "the reference grabbing interior elements at this flag's default");
    // The gesture is over, so the tool has dropped its snap snapshot; re-arm it
    // by hand or the master gate (task 0523) answers -1 for this call and the
    // assertion below would be about the gate rather than about `innerSnap`.
    off.t.dragSnap_ = *penTestSnapOn();
    assert(off.t.resolveSnapTargetVert(cast(int)projectedX(&mOff, 4, off.vp),
                                      cast(int)projectedY(&mOff, 4, off.vp), off.vp) < 0,
        "the SNAP TARGET must refuse the interior vertex at innerSnap = false");
    off.t.innerSnap_ = true;
    assert(off.t.resolveSnapTargetVert(cast(int)projectedX(&mOff, 4, off.vp),
                                      cast(int)projectedY(&mOff, 4, off.vp), off.vp) == 4,
        "and accept it with innerSnap on — which is what makes the refusal above the BORDER "
      ~ "rule's answer and not the radius's or the gate's");
    off.t.innerSnap_ = false;

    // --- innerSnap on: the very same drag splits.
    Mesh mOn;
    auto on = makeRig(true, &mOn);
    immutable size_t fBefore2 = mOn.faces.length;
    driveSplit(on, 0, 4);
    assert(mOn.faces.length == fBefore2 + 1,
        "with innerSnap on, the same corner-to-center drag must split the shared quad");
}

// ---------------------------------------------------------------------------
// Task 0496 — the DRAG-SNAP acceptance radius, measured at 24px, behaviourally.
//
// The press pick and the drag snap are two queries with two reaches, and this
// is the pin of the SECOND one. It goes through the real Split dispatch,
// because `resolveSnapTargetVert` is vibe3d's only "which existing element
// does this drag land on" query and Split's target vertex C is its only
// caller.
//
// Rig: `makeGridPlane(2)` seen from -Y (the side its quads face — task 0538,
// `makeGridPlaneFrontViewport`), 80px per cell. Quad [1,2,5,4] has BORDER
// vertices 1 and 5 on its diagonal — both border, so `innerSnap` is not in
// play here and this case isolates the RADIUS. Vertex 5 projects with 80px of
// clear space to every other vertex, so a release offset from it can be read
// as a distance to v5 and nothing else.
//
//   release 20px from v5 -> INSIDE the measured 24px acceptance -> the drag
//                           lands on v5 and the chord splits the quad.
//   release 26px from v5 -> outside it -> clean no-op.
//
// FAILS ON THE SHIPPED BEHAVIOUR: this resolver used to share the press pick's
// constant (15px, and ~8px after this change), under which the 20px release
// resolved nothing and the split never happened.
// ---------------------------------------------------------------------------
unittest {
    import view : View;
    import editmode : EditMode;
    import mesh : makeGridPlane;
    import toolpipe.packets : SubjectPacket;
    import constraint : topoPenSnapAcceptPx;
    import std.math : hypot;

    loadSDL();
    SDL_SetModState(cast(SDL_Keymod)0);

    // Split MUTATES on success, so each offset gets its own tool + mesh.
    // `snapPkt` is the SNAP configuration the press sees; null means "the
    // stage's own defaults, master enable on", which is the configuration the
    // ranges below were measured under and the one every assertion here but
    // the two explicit re-ranges runs.
    //
    // Task 0523: this used to default to NO packet at all, i.e. to the init
    // packet — whose ranges are the same but whose master enable is FALSE.
    // That distinction did not exist while the weld was unconditional; it does
    // now, and every case in this block is about the RADIUS, so every case
    // needs the gate open or it would be measuring the gate instead.
    static bool splitLands(float offsetPx, Mesh* m, out size_t facesBefore,
                           SnapPacket* snapPkt = null) {
        auto t       = new TopologyPenTool();
        auto view    = new View(0, 0, 100, 100);
        auto history = new CommandHistory();
        *m = makeGridPlane(2);
        t.meshSrc_          = () => m;
        t.history_          = history;
        t.innerSnap_        = false;         // the measured default, untouched
        t.splitEditFactory_ = () => new MeshSessionEdit(t.meshSrc_(), view, EditMode.Vertices,
                                                       "mesh.topoPen_split", "Topology Split",
                                                       MeshEditScope.Geometry);
        // The FRONT camera (task 0538) — this case's subject is the RADIUS, so
        // the geometry has to be on the side the pen will accept at all. See
        // `makeGridPlaneFrontViewport`.
        auto vp = makeGridPlaneFrontViewport();
        auto subj = new SubjectPacket();
        subj.mesh     = m;
        subj.viewport = vp;
        VectorStack vts;
        vts.put(subj);
        vts.put(snapPkt is null ? penTestSnapOn() : snapPkt);

        ImVec2 pa, pb;
        assert(TopologyPenTool.projectWorldPt(m.vertices[1], vp, pa), "setup: v1 must project");
        assert(TopologyPenTool.projectWorldPt(m.vertices[5], vp, pb), "setup: v5 must project");
        assert(!isVertexInterior(m, 1) && !isVertexInterior(m, 5),
            "setup: BOTH ends of this diagonal must be border vertices, so innerSnap is not the "
          ~ "thing under test here");

        facesBefore = m.faces.length;

        SDL_MouseButtonEvent down;
        down.button = SDL_BUTTON_MIDDLE;
        down.x = cast(int)pa.x; down.y = cast(int)pa.y;
        assert(t.onMouseButtonDown(down, vts), "a plain-MMB press on a vertex must consume");
        assert(t.splitArmed_ && t.splitSourceVert_ == 1, "and it must arm Split on v1");

        // Offset along +x from v5. On this camera screen-+x runs toward the
        // grid's centre, so the nearest OTHER vertex on that line is v4, one
        // full cell — 80px — away: every offset this block uses (20, 26) is
        // still unambiguously a distance to v5 and to nothing else.
        SDL_MouseButtonEvent up;
        up.button = SDL_BUTTON_MIDDLE;
        up.x = cast(int)(pb.x + offsetPx); up.y = cast(int)pb.y;
        assert(hypot(up.x - pb.x, up.y - pb.y) > offsetPx - 1.0f,
            "setup: the release must actually sit at the offset the case names");
        assert(t.onMouseButtonUp(up, vts), "a plain-MMB release must consume");
        return m.faces.length == facesBefore + 1;
    }

    Mesh mIn;
    size_t fIn;
    assert(splitLands(20.0f, &mIn, fIn),
        "a release 20px from the target vertex is INSIDE the measured 24px drag-snap acceptance "
      ~ "and must land on it, splitting the quad — before this fix the snap target shared the "
      ~ "press pick's constant and this release resolved nothing");

    Mesh mOut;
    size_t fOut;
    assert(!splitLands(26.0f, &mOut, fOut),
        "a release 26px away is outside the acceptance and must be a clean no-op");
    assert(mOut.faces.length == fOut && mOut.edges.length == 12,
        "and it must leave the grid untouched, not merely un-split");

    // The value last, as a label on the behaviour above rather than a
    // substitute for it. Note it is deliberately NOT the press-pick reach.
    auto vp = makeGridPlaneFrontViewport();
    assert(topoPenSnapAcceptPx(vp, SnapPacket.init) == 24.0f,
        "the drag-snap acceptance is 24px at scale 1, its own measured number — "
        ~ "and it is the snap service's default inner range, not a constant the "
        ~ "pen keeps for itself");

    // THE DE-DUPLICATION, as behaviour: 24px is a CONFIGURED number, so a
    // press that sees a narrower configured acceptance must land differently
    // at the very same pixel. The 20px release above split the quad; with the
    // acceptance moved to 12px it is a clean no-op, and nothing else changed.
    // This is the assertion a re-introduced private constant fails.
    SnapPacket narrow;
    narrow.enabled      = true;   // the gate open, so the RANGE is what decides
    narrow.innerRangePx = 12.0f;
    Mesh mNarrow;
    size_t fNarrow;
    assert(!splitLands(20.0f, &mNarrow, fNarrow, &narrow),
        "the acceptance is snap CONFIGURATION, not a constant the pen owns: at a "
        ~ "12px inner range the same 20px release must stop landing");
    assert(mNarrow.faces.length == fNarrow && mNarrow.edges.length == 12,
        "and the declined split must leave the grid untouched");

    // ... and widening it the other way re-lands the release the default
    // rejected, so the pen is reading the number rather than merely being
    // gated by one.
    SnapPacket wide;
    wide.enabled      = true;
    wide.innerRangePx = 40.0f;
    Mesh mWide;
    size_t fWide;
    assert(splitLands(26.0f, &mWide, fWide, &wide),
        "and at a 40px inner range the 26px release the default rejected must land");
}

version (unittest) private float projectedX(Mesh* m, uint vi, const ref Viewport vp) {
    ImVec2 p;
    assert(TopologyPenTool.projectWorldPt(m.vertices[vi], vp, p), "vertex must project");
    return p.x;
}

version (unittest) private float projectedY(Mesh* m, uint vi, const ref Viewport vp) {
    ImVec2 p;
    assert(TopologyPenTool.projectWorldPt(m.vertices[vi], vp, p), "vertex must project");
    return p.y;
}

// ---------------------------------------------------------------------------
// Remove — the ELEMENT-CLASS dispatch, the edge loop, Keep Vertices and the
// border no-op (task 0494).
//
// Every number below is a measured cell on a 4x4 planar grid, which is what
// `makeGridPlane(3)` is (16v/24e/9f, vertex index 4*row + col), so these
// assertions are the capture rows and not a re-derivation of our own code.
//
// The presses go through `onPlainLmbDown` — the real router — rather than
// calling the primitives directly, because the DISPATCH is the thing that
// changed: before this task every one of these presses deleted a polygon.
// Each test first asserts WHICH element class the press latches, so a failure
// says "the aim moved" or "the outcome moved" rather than leaving the two
// indistinguishable.
// ---------------------------------------------------------------------------
version (unittest) private TopologyPenTool makeRemoveTestTool(Mesh* m, CommandHistory h) {
    import view : View;
    import editmode : EditMode;
    auto t    = new TopologyPenTool();
    auto view = new View(0, 0, 100, 100);
    t.meshSrc_ = () => m;
    t.history_ = h;
    t.penMode_ = PenMode.Remove;
    // All three, with their own wire names — mirrors the app.d construction
    // site. Leaving one null would make its primitive a silent no-op and the
    // test would read as "the dispatch is wrong".
    t.removeEditFactory_ = () => new MeshSessionEdit(m, view, EditMode.Vertices,
                                 "mesh.topoPen_remove", "Topology Remove", MeshEditScope.Geometry);
    t.removeEdgeEditFactory_ = () => new MeshSessionEdit(m, view, EditMode.Vertices,
                                 "mesh.topoPen_removeedge", "Topology Remove Edge", MeshEditScope.Geometry);
    t.removeVertexEditFactory_ = () => new MeshSessionEdit(m, view, EditMode.Vertices,
                                 "mesh.topoPen_removevertex", "Topology Remove Vertex", MeshEditScope.Geometry);
    return t;
}

version (unittest) private SDL_MouseButtonEvent gridEdgeMidPixel(ref Mesh m, ref Viewport vp,
                                                                 uint a, uint b) {
    ImVec2 pa, pb;
    assert(TopologyPenTool.projectWorldPt(m.vertices[a], vp, pa), "setup: endpoint projects");
    assert(TopologyPenTool.projectWorldPt(m.vertices[b], vp, pb), "setup: endpoint projects");
    SDL_MouseButtonEvent e;
    e.x = cast(int)((pa.x + pb.x) * 0.5f);
    e.y = cast(int)((pa.y + pb.y) * 0.5f);
    return e;
}

version (unittest) private SDL_MouseButtonEvent gridVertPixel(ref Mesh m, ref Viewport vp, uint v) {
    ImVec2 p;
    assert(TopologyPenTool.projectWorldPt(m.vertices[v], vp, p), "setup: vertex projects");
    SDL_MouseButtonEvent e;
    e.x = cast(int)p.x;
    e.y = cast(int)p.y;
    return e;
}

version (unittest) private int gridVertAt(ref Mesh m, Vec3 p) {
    foreach (i, ref v; m.vertices)
        if (v.x == p.x && v.y == p.y && v.z == p.z) return cast(int)i;
    return -1;
}

unittest { // an EDGE-latched press DISSOLVES the edge — it does not remove a polygon
    import toolpipe.packets : SubjectPacket;
    import mesh : makeGridPlane;

    Mesh m   = makeGridPlane(3);
    auto vp  = makeGridPlaneTestViewport();
    auto history = new CommandHistory();
    auto t   = makeRemoveTestTool(&m, history);

    SubjectPacket subj;
    subj.mesh = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    immutable uint seed = m.edgeIndex(5, 9);
    auto e = gridEdgeMidPixel(m, vp, 5, 9);
    int idx;
    assert(t.resolveGrabTarget(e.x, e.y, vp, idx) == MoveElem.Edge && idx == cast(int)seed,
        "setup: the press must LATCH THE INTERIOR EDGE, or this measures the aim");

    assert(t.onPlainLmbDown(e, vts), "a Remove press is always consumed");

    assert(m.vertices.length == 16 && m.edges.length == 23 && m.faces.length == 8,
        "an edge-latched Remove dissolves ONE edge: 16/23/8. The pre-0494 behaviour "
      ~ "was 16/24/8 — one polygon gone, no edge — which is what this pins against");
    assert(m.edgeIndex(5, 9) == ~0u, "and it is the pressed edge that went");
    assert(m.edgeIndex(4, 5) != ~0u && m.edgeIndex(5, 6) != ~0u,
        "its neighbours are untouched");

    // The two quads it separated are now ONE hexagon, and nothing else moved.
    size_t hexes = 0;
    foreach (ref f; m.faces) {
        if (f.length == 4) continue;
        assert(f.length == 6, "the merge produces a hexagon, nothing else");
        ++hexes;
        uint[] got = f.dup;
        import std.algorithm : sort;
        got.sort();
        assert(got == [4u, 5u, 6u, 8u, 9u, 10u], "the union of the two incident quads");
    }
    assert(hexes == 1);
    assert(history.canUndo(), "a real removal records one undo entry");
}

unittest { // a VERTEX-latched press merges its whole fan and drops the vertex
    import toolpipe.packets : SubjectPacket;
    import mesh : makeGridPlane;

    Mesh m   = makeGridPlane(3);
    auto vp  = makeGridPlaneTestViewport();
    auto history = new CommandHistory();
    auto t   = makeRemoveTestTool(&m, history);

    SubjectPacket subj;
    subj.mesh = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    auto pre = m.vertices.dup;
    auto e   = gridVertPixel(m, vp, 5);
    int idx;
    assert(t.resolveGrabTarget(e.x, e.y, vp, idx) == MoveElem.Vertex && idx == 5,
        "setup: the press must LATCH THE VERTEX");

    assert(t.onPlainLmbDown(e, vts));

    assert(m.vertices.length == 15 && m.edges.length == 20 && m.faces.length == 6,
        "the four quads around vertex 5 become ONE 8-gon and only vertex 5 goes: 15/20/6");
    assert(gridVertAt(m, pre[5]) < 0, "the pressed vertex is gone");
    foreach (keep; [1, 4, 6, 9])
        assert(gridVertAt(m, pre[keep]) >= 0,
            "and ONLY it — the vertex primitive is not the edge path's fan rule, which "
          ~ "would also have taken 1 and 4 (13/18/6)");

    size_t bigs = 0;
    foreach (ref f; m.faces) if (f.length != 4) { assert(f.length == 8); ++bigs; }
    assert(bigs == 1, "exactly one 8-gon");
}

unittest { // a CORNER vertex (one incident polygon): the merge is vacuous and
           // the quad collapses to a triangle
    import toolpipe.packets : SubjectPacket;
    import mesh : makeGridPlane;

    Mesh m   = makeGridPlane(3);
    auto vp  = makeGridPlaneTestViewport();
    auto history = new CommandHistory();
    auto t   = makeRemoveTestTool(&m, history);

    SubjectPacket subj;
    subj.mesh = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    auto pre = m.vertices.dup;
    auto e   = gridVertPixel(m, vp, 0);
    int idx;
    assert(t.resolveGrabTarget(e.x, e.y, vp, idx) == MoveElem.Vertex && idx == 0,
        "setup: the press must LATCH THE CORNER VERTEX");

    assert(t.onPlainLmbDown(e, vts));

    assert(m.vertices.length == 15 && m.edges.length == 23 && m.faces.length == 9,
        "15/23/9 — the corner quad becomes a triangle and no polygon is lost");
    assert(gridVertAt(m, pre[0]) < 0);
    immutable int v1 = gridVertAt(m, pre[1]);
    immutable int v4 = gridVertAt(m, pre[4]);
    assert(v1 >= 0 && v4 >= 0 && m.edgeIndex(cast(uint)v1, cast(uint)v4) != ~0u,
        "the triangle's new edge closes across the removed corner");
    size_t tris = 0;
    foreach (ref f; m.faces) if (f.length == 3) ++tris;
    assert(tris == 1, "exactly one triangle");
}

unittest { // Edge Loop + Keep Vertices, both ways round, on an edge-latched press
    import toolpipe.packets : SubjectPacket;
    import mesh : makeGridPlane;

    // Runs one Remove press with the given flags and hands the mesh back.
    static void press(ref Mesh m, bool loop, bool keepVertex, ref CommandHistory h) {
        auto vp = makeGridPlaneTestViewport();
        auto t  = makeRemoveTestTool(&m, h);
        t.edgeLoop_   = loop;
        t.keepVertex_ = keepVertex;

        SubjectPacket subj;
        subj.mesh = &m;
        subj.viewport = vp;
        VectorStack vts;
        vts.put(&subj);

        auto e = gridEdgeMidPixel(m, vp, 5, 9);
        int idx;
        assert(t.resolveGrabTarget(e.x, e.y, vp, idx) == MoveElem.Edge
            && idx == cast(int)m.edgeIndex(5, 9), "setup: the press must latch the seed edge");
        assert(t.onPlainLmbDown(e, vts));
    }

    // Keep Vertices ON: the three loop edges dissolve, every vertex stays as a
    // corner of a merged hexagon.
    {
        Mesh m = makeGridPlane(3);
        auto h = new CommandHistory();
        press(m, /*loop*/true, /*keepVertex*/true, h);
        assert(m.vertices.length == 16 && m.edges.length == 21 && m.faces.length == 6,
            "16/21/6");
        assert(m.edgeIndex(1, 5) == ~0u && m.edgeIndex(5, 9) == ~0u
            && m.edgeIndex(9, 13) == ~0u,
            "the gather is the vertex-continuation loop through the seed — exactly "
          ~ "those three, which is also what refutes a perpendicular ring");
        assert(m.edgeIndex(4, 5) != ~0u && m.edgeIndex(5, 6) != ~0u,
            "and nothing perpendicular to it");
    }

    // Keep Vertices OFF — the measured DEFAULT: the four vertices whose whole
    // polygon fan the dissolve ate go with it, and their survivors re-stitch.
    {
        Mesh m   = makeGridPlane(3);
        auto pre = m.vertices.dup;
        auto h   = new CommandHistory();
        press(m, /*loop*/true, /*keepVertex*/false, h);
        assert(m.vertices.length == 12 && m.edges.length == 17 && m.faces.length == 6,
            "12/17/6 — this is what the tool now does by DEFAULT, where before this "
          ~ "task it kept the orphans unconditionally (the Keep-Vertices-ON branch)");
        foreach (gone; [1, 5, 9, 13])
            assert(gridVertAt(m, pre[gone]) < 0, "the consumed vertices go");
        assert(gridVertAt(m, pre[4]) >= 0,
            "but NOT vertex 4, whose fan is equally consumed and which is nobody's "
          ~ "dissolving endpoint");
        foreach (pair; [[0, 2], [4, 6], [8, 10], [12, 14]]) {
            immutable int a = gridVertAt(m, pre[pair[0]]), b = gridVertAt(m, pre[pair[1]]);
            assert(a >= 0 && b >= 0 && m.edgeIndex(cast(uint)a, cast(uint)b) != ~0u,
                "and the survivors are re-stitched across the gap");
        }
        assert(m.vertices.length - m.edges.length + m.faces.length == 1, "Euler");
    }

    // And the DEFAULT tool takes the OFF branch — the flag's default is the
    // behaviour, not a formality.
    {
        Mesh m = makeGridPlane(3);
        auto h = new CommandHistory();
        auto t = makeRemoveTestTool(&m, h);
        assert(!t.keepVertex_, "a fresh tool must purge");
    }
}

unittest { // the loop variant keys on the EFFECTIVE flag, never on the button
    import toolpipe.packets : SubjectPacket;
    import mesh : makeGridPlane;

    // The chord that FORCES the loop flag, against a plain press with the flag
    // set by the user. These were measured bit-identical down to the removed-
    // edge / new-edge / removed-vertex sets, so the port must not be able to
    // tell them apart either.
    static Mesh run(bool viaChord) {
        Mesh m  = makeGridPlane(3);
        auto vp = makeGridPlaneTestViewport();
        auto h  = new CommandHistory();
        auto t  = makeRemoveTestTool(&m, h);
        t.edgeLoop_ = !viaChord;   // the chord supplies it in the other arm

        SubjectPacket subj;
        subj.mesh = &m;
        subj.viewport = vp;
        VectorStack vts;
        vts.put(&subj);

        auto e = gridEdgeMidPixel(m, vp, 5, 9);
        if (viaChord)
            t.onToolAction(TopoPenChord.Rmb, InputPhase.Down, e, vts);
        else
            t.onPlainLmbDown(e, vts);
        return m;
    }

    Mesh viaFlag  = run(false);
    Mesh viaChord = run(true);
    assert(viaFlag.vertices == viaChord.vertices, "same vertices");
    assert(viaFlag.edges    == viaChord.edges,    "same edges");
    assert(viaFlag.faces    == viaChord.faces,    "same faces");
    assert(viaFlag.vertices.length == 12 && viaFlag.edges.length == 17
        && viaFlag.faces.length == 6, "and both ran the LOOP variant");
}

unittest { // a BORDER seed is a TOTAL no-op, in BOTH variants
    import toolpipe.packets : SubjectPacket;
    import mesh : makeGridPlane;

    foreach (loop; [false, true]) {
        Mesh m   = makeGridPlane(3);
        auto vp  = makeGridPlaneTestViewport();
        auto h   = new CommandHistory();
        auto t   = makeRemoveTestTool(&m, h);
        t.edgeLoop_ = loop;

        SubjectPacket subj;
        subj.mesh = &m;
        subj.viewport = vp;
        VectorStack vts;
        vts.put(&subj);

        auto before = MeshSnapshot.capture(m);
        auto e = gridEdgeMidPixel(m, vp, 0, 1);   // top-left BORDER edge
        int idx;
        assert(t.resolveGrabTarget(e.x, e.y, vp, idx) == MoveElem.Edge
            && idx == cast(int)m.edgeIndex(0, 1), "setup: the press must latch the border edge");

        assert(t.onPlainLmbDown(e, vts), "still consumed");

        auto after = MeshSnapshot.capture(m);
        assert(after.vertices == before.vertices && after.edges == before.edges
            && after.faces == before.faces,
            "16/24/9 and not one vertex moved");
        assert(!h.canUndo(), "and no undo entry is recorded");
    }
}

unittest { // ...and the seed gate is a GATE, not the kernel's per-edge skip
    // Honest note on the block above: it does NOT discriminate. On a border
    // seed the dissolve kernel skips the edge anyway, so deleting the seed gate
    // outright leaves every assertion there green — verified by mutation. No
    // BORDER fixture can separate the two, either: a border seed's loop gather
    // walks the open boundary, so everything it returns is a border edge too.
    //
    // A NON-MANIFOLD seed does separate them, and it is the case the measured
    // rule actually names — the gate is "exactly two incident polygons", not
    // "not a border". Three quads share edge 0-1 here. The gate declines it;
    // the kernel would NOT, because its own adjacency keeps the first two
    // distinct faces per edge and would merrily merge those two.
    Mesh m;
    foreach (p; [Vec3(0,0,0), Vec3(1,0,0), Vec3(0,1,0), Vec3(1,1,0),
                 Vec3(0,0,1), Vec3(1,0,1), Vec3(0,-1,0), Vec3(1,-1,0)])
        m.addVertex(p);
    m.addFace([0u, 1u, 3u, 2u]);
    m.addFace([0u, 1u, 5u, 4u]);
    m.addFace([0u, 1u, 7u, 6u]);
    m.buildLoops();

    immutable uint seed = m.edgeIndex(0, 1);
    assert(m.edgePolygonCounts()[seed] == 3,
        "setup: the count must SEE all three — the half-edge rings report 1 here, "
      ~ "which is why this tool counts off the faces instead");

    auto h = new CommandHistory();
    auto t = makeRemoveTestTool(&m, h);
    auto before = MeshSnapshot.capture(m);
    foreach (loop; [false, true]) {
        t.edgeLoop_ = loop;
        t.removeEdgeAt(cast(int)seed, loop);
    }
    auto after = MeshSnapshot.capture(m);
    assert(after.vertices == before.vertices && after.edges == before.edges
        && after.faces == before.faces,
        "a seed with other than exactly two incident polygons is a TOTAL no-op");
    assert(!h.canUndo(), "and records nothing");
}

unittest { // one undo restores counts AND positions, for all three primitives
    import toolpipe.packets : SubjectPacket;
    import mesh : makeGridPlane;

    static void roundTrip(bool loop, uint a, uint b, bool vertexPress, uint v) {
        Mesh m  = makeGridPlane(3);
        auto vp = makeGridPlaneTestViewport();
        auto h  = new CommandHistory();
        auto t  = makeRemoveTestTool(&m, h);
        t.edgeLoop_ = loop;

        SubjectPacket subj;
        subj.mesh = &m;
        subj.viewport = vp;
        VectorStack vts;
        vts.put(&subj);

        auto before = MeshSnapshot.capture(m);
        auto e = vertexPress ? gridVertPixel(m, vp, v) : gridEdgeMidPixel(m, vp, a, b);
        assert(t.onPlainLmbDown(e, vts));
        assert(h.canUndo(), "the gesture must be undoable");
        h.undo();
        auto after = MeshSnapshot.capture(m);
        assert(after.vertices == before.vertices && after.edges == before.edges
            && after.faces == before.faces,
            "ONE undo must restore counts AND positions — the whole gesture is one step");
    }

    roundTrip(/*loop*/false, 5, 9, false, 0);   // edge dissolve
    roundTrip(/*loop*/true,  5, 9, false, 0);   // edge loop dissolve (+ the purge)
    roundTrip(/*loop*/false, 0, 0, true,  5);   // vertex fan merge
}

unittest { // Keep Vertices reaches the EDGE path and nothing else
    import toolpipe.packets : SubjectPacket;
    import mesh : makeGridPlane;

    // Measured only on the edge path, and the reference reads the flag in
    // neither of the other two primitives — so honouring it there would be
    // inventing a second meaning for it.
    foreach (keep; [false, true]) {
        Mesh m  = makeGridPlane(3);
        auto vp = makeGridPlaneTestViewport();
        auto h  = new CommandHistory();
        auto t  = makeRemoveTestTool(&m, h);
        t.keepVertex_ = keep;

        SubjectPacket subj;
        subj.mesh = &m;
        subj.viewport = vp;
        VectorStack vts;
        vts.put(&subj);

        auto e = gridVertPixel(m, vp, 5);
        assert(t.onPlainLmbDown(e, vts));
        assert(m.vertices.length == 15 && m.edges.length == 20 && m.faces.length == 6,
            "the vertex primitive ignores Keep Vertices in both positions");
    }
}

unittest { // a bare retopo chain elsewhere in the mesh SURVIVES a dissolve
    import toolpipe.packets : SubjectPacket;
    import mesh : makeGridPlane;

    // vibe3d-side contract, not a ported behaviour (`captureWireEdges`): this
    // tool builds face-less edges as an ordinary intermediate state, and the
    // dissolve kernels re-derive the edge array from the faces, which would
    // otherwise wipe every one of them mesh-wide — related to the edit or not.
    Mesh m  = makeGridPlane(3);
    auto vp = makeGridPlaneTestViewport();
    auto h  = new CommandHistory();
    auto t  = makeRemoveTestTool(&m, h);

    // Two loose vertices joined by a bare edge, plus one placed point with no
    // edge at all — well away from the grid, and all three face-less.
    immutable uint w0 = m.addVertex(Vec3(5, 0, 5));
    immutable uint w1 = m.addVertex(Vec3(6, 0, 5));
    immutable uint w2 = m.addVertex(Vec3(7, 0, 5));
    m.addEdge(w0, w1);
    m.buildLoops();
    auto wa = m.vertices[w0], wb = m.vertices[w1], wc = m.vertices[w2];
    assert(m.edges.length == 25, "setup: 24 grid edges plus the wire");

    SubjectPacket subj;
    subj.mesh = &m;
    subj.viewport = vp;
    VectorStack vts;
    vts.put(&subj);

    auto e = gridEdgeMidPixel(m, vp, 5, 9);
    assert(t.onPlainLmbDown(e, vts));

    immutable int a = gridVertAt(m, wa), b = gridVertAt(m, wb);
    assert(a >= 0 && b >= 0, "the wire's endpoints must survive");
    assert(m.edgeIndex(cast(uint)a, cast(uint)b) != ~0u,
        "and so must the bare edge between them");
    assert(gridVertAt(m, wc) >= 0,
        "and so must a placed point with no edge at all — the kernel's tail compaction "
      ~ "drops every face-less vertex in the mesh, not only the ones this edit touched");
}

// ---------------------------------------------------------------------------
// THE PRESS PICK'S VERTEX-SLOT VETO.
//
// A press whose cursor is nearer the winning edge's MIDPOINT than it is to the
// best vertex grabs the EDGE, even though the vertex is comfortably inside the
// press-pick reach and the ordinary cascade would have answered `Vertex`.
//
// THE PAIR IS BUILT SO EVERYTHING ELSE IS EQUAL. One mesh, one edge, one
// contested vertex, and TWO cursors five pixels apart. In both of them the
// vertex is in range AND the edge is in range — a rig where only one type
// resolves cannot see the veto at all, because the veto's whole subject is
// which of two live candidates the press takes. What differs between the two
// cursors is only the sign of `midpoint-distance − vertex-distance`, so an
// answer that differs between them can be nothing but the veto.
//
// The range clause (`dMid < press reach`) is deliberately NOT probed here, and
// that is a statement about this call site rather than an omission: the pen's
// press pick is type-uniform — one reach, no doubled tolerance for the vertex
// class — so a vertex that resolved at all is already inside the reach, and
// `dMid < dVert <= reach` makes the clause vacuous by construction. It is kept
// in the code because it is the rule, not because it is reachable from here.
// (The snapping service's copy of the veto DOES have an observable range
// clause, because there the vertex class carries a doubled tolerance and can
// be resolved from outside the acceptance range; that block tests it.)
// ---------------------------------------------------------------------------
unittest {
    import std.math : hypot;
    import toolpipe.packets : SubjectPacket;

    auto t = new TopologyPenTool();

    // 80 px per world unit at z = 0 under this viewport: screen = (400 + 80x,
    // 400 - 80y). Every pixel quoted below is that identity, and every one of
    // them is asserted rather than trusted.
    auto vp = makeHoverIndicatorTestViewport();

    Mesh m;
    m.vertices = [
        Vec3( 0.00f,  0.00f, 0),   // 0 — the contested vertex, px (400, 400)
        Vec3(-0.45f,  0.05f, 0),   // 1 — edge end,             px (364, 396)
        Vec3( 0.55f, -0.05f, 0),   // 2 — edge end,             px (444, 404)
    ];
    m.edges = [ [1u, 2u] ];        // midpoint (0.05, 0, 0) -> px (404, 400)
    t.meshSrc_ = () => &m;

    ImVec2 pv, pmid;
    assert(TopologyPenTool.projectWorldPt(m.vertices[0], vp, pv), "setup: the vertex must project");
    // The projection of the WORLD midpoint, which is what the rule measures —
    // not the midpoint of the two projected endpoints. On this z = 0 rig the
    // two coincide, but the rule is stated on the world point and the fixture
    // has to ask the same question the code does.
    assert(TopologyPenTool.projectWorldPt((m.vertices[1] + m.vertices[2]) * 0.5f, vp, pmid),
        "setup: the edge midpoint must project");

    immutable float reach = topoPenPressPickPx(vp);

    // ---- CURSOR A: out along the edge. The midpoint beats the vertex. ------
    {
        immutable int cx = 405, cy = 400;
        immutable float dVert = hypot(pv.x   - cx, pv.y   - cy);
        immutable float dMid  = hypot(pmid.x - cx, pmid.y - cy);

        assert(t.findSourceVertex(cx, cy, vp) == 0,
            "setup: the vertex must resolve — a rig where it does not cannot "
            ~ "show a veto, because there would be no slot to clear");
        assert(t.findRingSeedEdge(cx, cy, vp) == 0,
            "setup: and the edge must resolve too, or the veto has nothing to "
            ~ "veto WITH and nothing to fall through to");
        assert(dVert < reach && dVert > 1.0f,
            "setup: the vertex must be comfortably inside the reach, so that "
            ~ "an answer of Edge cannot be explained by the vertex falling out "
            ~ "of range");
        assert(dMid < dVert,
            "setup: and the midpoint must be the NEARER of the two — that "
            ~ "inequality IS the veto's condition");

        int idx = -99;
        immutable auto got = t.resolveGrabTarget(cx, cy, vp, idx);
        assert(got == MoveElem.Edge && idx == 0,
            "the press pick must clear the vertex slot and answer with the "
            ~ "EDGE: the cursor is nearer that edge's midpoint than it is to "
            ~ "the vertex. Answering Vertex here means the veto is not "
            ~ "modelled — the plain vertex-then-edge cascade");
    }

    // ---- CURSOR B: parked on the vertex. The vertex beats the midpoint. ----
    {
        immutable int cx = 400, cy = 400;
        immutable float dVert = hypot(pv.x   - cx, pv.y   - cy);
        immutable float dMid  = hypot(pmid.x - cx, pmid.y - cy);

        assert(t.findSourceVertex(cx, cy, vp) == 0,
            "setup: the same vertex must resolve");
        assert(t.findRingSeedEdge(cx, cy, vp) == 0,
            "setup: and the SAME edge must still resolve, so the two cursors "
            ~ "differ in nothing but the two distances below");
        assert(dMid < reach,
            "setup: the midpoint is still inside the reach, so this control "
            ~ "isolates the NEARER clause and not the range one");
        assert(dVert < dMid,
            "setup: and here the vertex is the nearer of the two");

        int idx = -99;
        immutable auto got = t.resolveGrabTarget(cx, cy, vp, idx);
        assert(got == MoveElem.Vertex && idx == 0,
            "the veto must NOT fire when the vertex is the nearer of the two. "
            ~ "Answering Edge here means the rule was ported without its "
            ~ "comparison and now demotes every vertex that has an edge beside "
            ~ "it — which is every vertex in a mesh");
    }

    // ---- The SECOND press cascade: Duplicate's slot runs the same veto. ----
    // `onShiftLmbDown` does its own vertex-then-edge pick rather than going
    // through `resolveGrabTarget`, so a veto wired into only one of the two
    // would leave the pen's own press paths disagreeing about which element a
    // press grabs.
    {
        SubjectPacket subj;
        subj.mesh     = &m;
        subj.viewport = vp;
        VectorStack vts;
        vts.put(&subj);

        SDL_MouseButtonEvent eA;
        eA.x = 405; eA.y = 400;
        t.resetAllGestureArms();
        assert(t.onShiftLmbDown(eA, vts), "the press must still be consumed");
        assert(!t.dragArmed_,
            "Duplicate's slot must not take the vertex drag-build when the "
            ~ "veto cleared the vertex — its pick sees the same two candidates "
            ~ "`resolveGrabTarget` does and must resolve them the same way");
        assert(t.anyGestureArmed(),
            "and it must have armed the edge outcome rather than declining: a "
            ~ "veto that turns a live press into a no-op is not the rule");

        SDL_MouseButtonEvent eB;
        eB.x = 400; eB.y = 400;
        t.resetAllGestureArms();
        assert(t.onShiftLmbDown(eB, vts), "the control press must be consumed");
        assert(t.dragArmed_ && t.sourceVert_ == 0,
            "and on the vertex the drag-build must still arm, untouched — the "
            ~ "veto is a comparison, not a ban on grabbing vertices");
    }
}

// ===========================================================================
// TASK 0619 — the snap guide's ORIENTATION admission across a layer transform
// (P6, doc/tool_aiming_item_transform_plan.md §1.4 and §Phase 0's two-fixture
// table). Two blocks, because ONE fixture cannot separate the three candidate
// laws from each other:
//
//   A  the geometric outward normal — ADOPTED:
//        dot(n_local, ms.toLocalDir(d_world)) == dot((M^-1)^T n, d)   exactly
//   B  the world WINDING normal:  sign(det M) * A
//   C  what the lit vertex shader shades with (shader.d:136): dot(mat3(M)·n, d)
//   PRE  what this code did before 0619: dot(n_local, d_world) — a local
//        normal against a world ray, i.e. no transform at all
//
// Under a MIRROR the matrix is orthogonal, so `mat3(M) == (M^-1)^T` and C
// collapses onto A: that fixture separates B (and PRE) only. Under a
// non-uniform scale `det > 0`, so B collapses onto A: that fixture separates
// C only. Hence two blocks, and each one asserts its own separation BEFORE it
// asserts the verdict — a fixture that stopped separating would fail loudly
// instead of passing vacuously.
//
// THE INSTRUMENT. `PenSnapGuide` is constructed directly and its own
// `aimDir_` is read back, so every candidate below is evaluated against the
// ray the guide ACTUALLY holds rather than against one the test assumes. The
// expected verdict is derived by the INVERSE-TRANSPOSE route
// (`ms.toWorldNormal`), which is a different expression from the
// implementation's (`ms.toLocalDir` on the ray) — so the assertion cannot be
// a restatement of the code under test. Nothing here reads the GPU/BVH
// identity picker, which is two-sided (`bvh_pick.d:814-816`) and blind to
// every facing question (plan R11).
//
// `interiorOk = true` on both `retarget` calls: the border half of the
// admission rule is switched off so ORIENTATION is the only thing measured.
//
// NOTE for the standing "`ms.mirrored` is read nowhere" gate (0617): the two
// blocks below DO read it — as the `sign(det M)` factor of candidate B, the
// law they exist to REFUTE, and only inside a unittest. Production code in
// this file still never reads it, and must not start.
// ===========================================================================

// A deliberately lopsided fan around vertex 0 — asymmetric on all three axes,
// and NOT symmetric about any coordinate plane, so a mirror cannot map its
// vertex set onto itself (the fixture shape that shipped 0617's bug). Its
// summed fan normal is OBLIQUE, which is what P6b's non-uniform separation
// needs: an axis-aligned normal makes A and C differ only by a positive
// factor and the case goes vacuous.
version (unittest) private Mesh makeObliqueFanRig() {
    Mesh m;
    m.addVertex(Vec3( 0.00f,  0.00f,  0.00f));   // 0 — the fan apex
    m.addVertex(Vec3( 1.00f,  0.40f,  0.05f));   // 1
    m.addVertex(Vec3( 0.30f,  0.20f,  1.00f));   // 2
    m.addVertex(Vec3(-0.80f,  0.55f,  0.40f));   // 3
    m.addFace([0, 1, 2]);
    m.addFace([0, 2, 3]);
    m.buildLoops();
    return m;
}

// The summed fan normal `orientationAdmits` builds, recomputed here from the
// mesh's own `faceNormal` so the candidates below all start from the same
// LOCAL vector the implementation starts from.
version (unittest) private Vec3 fanNormalLocal(Mesh* m, uint vi) {
    Vec3 n = Vec3(0, 0, 0);
    foreach (fi; m.facesAroundVertex(vi)) n = n + m.faceNormal(cast(uint)fi);
    return n;
}

// The linear part of `ms.m` applied to a vector — candidate C's transport,
// i.e. `mat3(u_model) * aNormal` as `shader.d:136` writes it. Column-major,
// same indexing `math.applyAffine` uses minus the translation column.
version (unittest) private Vec3 shaderNormalWorld(const ModelSpace ms, Vec3 nLocal) {
    return Vec3(ms.m[0]*nLocal.x + ms.m[4]*nLocal.y + ms.m[ 8]*nLocal.z,
                ms.m[1]*nLocal.x + ms.m[5]*nLocal.y + ms.m[ 9]*nLocal.z,
                ms.m[2]*nLocal.x + ms.m[6]*nLocal.y + ms.m[10]*nLocal.z);
}

// A perspective viewport whose centre-pixel ray points along `dir`.
version (unittest) private Viewport viewportAlong(Vec3 dir, Vec3 focus) {
    import math : lookAt, perspectiveMatrix, normalize;
    import std.math : PI, fabs;
    Vec3 d = normalize(dir);
    Viewport vp;
    vp.eye    = focus - d * 6.0f;
    // Any `up` not parallel to `d`; picked by the smallest |component| so the
    // choice is deterministic and never degenerate.
    Vec3 up = (fabs(d.y) < 0.9f) ? Vec3(0, 1, 0) : Vec3(1, 0, 0);
    vp.view   = lookAt(vp.eye, focus, up);
    vp.proj   = perspectiveMatrix(PI / 3, 1.0f, 0.1f, 100.0f);
    vp.width  = 800; vp.height = 800; vp.x = 0; vp.y = 0;
    vp.focus  = focus;
    return vp;
}

unittest { // P6a — MIRROR. Separates candidate B (and the pre-0619 law) from A.
    import document : ItemXform, primaryModelSpaceResolver;
    import math : normalize;
    import std.format : format;

    Mesh m = makeObliqueFanRig();
    Mesh* mp = &m;

    // scl.x = -1 -> det(M) < 0. Rotation on all three axes as well, so the
    // fixture is not the "mirror alone on a symmetric cube" shape 0617's retro
    // forbids: nothing here maps its own vertex set to itself.
    ItemXform xf;
    xf.pos = Vec3(0.9f, -0.45f, 0.30f);
    xf.rot = Vec3(13.0f, 38.0f, -9.0f);
    xf.scl = Vec3(-1.0f, 1.0f, 1.0f);
    const ModelSpace ms = xf.modelSpace();
    assert(ms.mirrored, "setup: scl.x = -1 must produce a mirrored ModelSpace");

    auto saved = primaryModelSpaceResolver;
    scope(exit) primaryModelSpaceResolver = saved;
    primaryModelSpaceResolver = () => ms;

    Vec3 nLocal = fanNormalLocal(mp, 0);
    assert(nLocal.length > 1e-3f, "setup: the fan normal must not be degenerate");

    // Aim so that the ADOPTED law and the pre-0619 law land on OPPOSITE sides
    // of the ray. `w - u` is on the far side of `u` and the near side of `w`
    // for any two non-parallel unit vectors, which is exactly that.
    Vec3 nAdopted = normalize(ms.toWorldNormal(nLocal));   // (M^-1)^T n
    Vec3 nPre     = normalize(nLocal);                     // what the old code dotted
    Viewport vp   = viewportAlong(nPre - nAdopted, ms.toWorldPoint(Vec3(0, 0, 0)));

    auto g = new PenSnapGuide();
    g.retarget(mp, true);            // interior filter OFF: orientation only
    g.aimAt(vp, vp.width / 2, vp.height / 2);

    // Every candidate, evaluated against the ray the guide ACTUALLY holds.
    immutable float dA   = dot(ms.toWorldNormal(nLocal), g.aimDir_);
    immutable float dB   = (ms.mirrored ? -1.0f : 1.0f) * dA;
    immutable float dC   = dot(shaderNormalWorld(ms, nLocal), g.aimDir_);
    immutable float dPre = dot(nLocal, g.aimDir_);

    // ANTI-VACUITY. Each candidate must be far enough from zero to have a
    // sign at all, and the ones this fixture is here to separate must
    // genuinely predict the opposite verdict.
    assert(dA > 1e-3f || dA < -1e-3f, "candidate A sits on the ray — no verdict to read");
    assert((dA > 0) != (dB > 0),
        "vacuous: the mirror fixture must separate the winding-normal law from the adopted one");
    assert((dA > 0) != (dPre > 0),
        "vacuous: this fixture must separate the PRE-0619 law (local normal vs world ray) "
        ~ "from the adopted one, or the break check below could not fail");
    // ...and the one it CANNOT separate, asserted so the reason is on record
    // rather than assumed: under a mirror `M` is orthogonal, so `mat3(M)`
    // equals the inverse-transpose and the lit-shader law IS the adopted one
    // here. That is why P6b exists.
    assert((dA > 0) == (dC > 0),
        "a mirror cannot separate the lit-shader law from the adopted one — if it "
        ~ "suddenly does, this fixture is not the mirror it claims to be");

    immutable bool expected = !(dA > 0.0f);   // the rule: a positive dot REFUSES
    assert(g.admits(SnapType.Vertex, 0, 0) == expected, format(
        "the orientation verdict must follow the geometric outward normal (candidate A), "
        ~ "derived here through the inverse-transpose rather than by re-running the tool; "
        ~ "admits=%s expected=%s  dA=%.5f dB=%.5f dC=%.5f dPre=%.5f",
        g.admits(SnapType.Vertex, 0, 0), expected, dA, dB, dC, dPre));
}

unittest { // P6b — NON-UNIFORM SCALE. Separates candidate C from A.
    import document : ItemXform, primaryModelSpaceResolver;
    import math : normalize;
    import std.format : format;

    Mesh m = makeObliqueFanRig();
    Mesh* mp = &m;

    // det(M) > 0, so candidate B collapses onto A here and this fixture is
    // blind to it — which is the whole reason P6a is a separate block.
    ItemXform xf;
    xf.pos = Vec3(0.9f, -0.45f, 0.30f);
    xf.rot = Vec3(13.0f, 38.0f, -9.0f);
    xf.scl = Vec3(1.7f, 1.0f, 0.6f);
    const ModelSpace ms = xf.modelSpace();
    assert(!ms.mirrored, "setup: this fixture must NOT be mirrored");

    auto saved = primaryModelSpaceResolver;
    scope(exit) primaryModelSpaceResolver = saved;
    primaryModelSpaceResolver = () => ms;

    Vec3 nLocal = fanNormalLocal(mp, 0);
    assert(nLocal.length > 1e-3f, "setup: the fan normal must not be degenerate");

    // The GRAZING aim the plan asks for, constructed rather than searched:
    // the two transports of the same normal are not parallel under a
    // non-uniform scale, and `w - u` straddles them.
    Vec3 nAdopted = normalize(ms.toWorldNormal(nLocal));            // (M^-1)^T n
    Vec3 nShader  = normalize(shaderNormalWorld(ms, nLocal));       // mat3(M) n
    Viewport vp   = viewportAlong(nShader - nAdopted, ms.toWorldPoint(Vec3(0, 0, 0)));

    auto g = new PenSnapGuide();
    g.retarget(mp, true);
    g.aimAt(vp, vp.width / 2, vp.height / 2);

    immutable float dA = dot(ms.toWorldNormal(nLocal), g.aimDir_);
    immutable float dB = (ms.mirrored ? -1.0f : 1.0f) * dA;
    immutable float dC = dot(shaderNormalWorld(ms, nLocal), g.aimDir_);

    assert(dA > 1e-3f || dA < -1e-3f, "candidate A sits on the ray — no verdict to read");
    assert((dA > 0) != (dC > 0),
        "vacuous: the non-uniform fixture must separate the lit-shader law from the "
        ~ "adopted one, or it measures nothing P6a did not already measure");
    assert((dA > 0) == (dB > 0),
        "det(M) > 0 here, so the winding-normal law MUST collapse onto the adopted one — "
        ~ "if it does not, this fixture is secretly mirrored");

    immutable bool expected = !(dA > 0.0f);
    assert(g.admits(SnapType.Vertex, 0, 0) == expected, format(
        "the orientation verdict must follow the geometric outward normal, NOT the normal "
        ~ "the lit vertex shader transports (shader.d:136 — a pre-existing shading defect, "
        ~ "plan R10, deliberately not imported into a picking predicate); "
        ~ "admits=%s expected=%s  dA=%.5f dB=%.5f dC=%.5f",
        g.admits(SnapType.Vertex, 0, 0), expected, dA, dB, dC));
}
