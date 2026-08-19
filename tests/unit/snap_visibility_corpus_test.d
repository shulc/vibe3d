// The snap VISIBILITY-MASK corpus (task 1351, Ф1).
//
// WHY A SECOND CORPUS, when `snap_election_corpus_test.d` already exists.
// That one compares the WINNER of a snap election, and the winner is exactly
// the thing a broad phase cannot change: "a superset of candidates, re-tested
// by an UNCHANGED exact predicate" elects the same point no matter how the
// superset was gathered. Measured, not assumed — the election corpus produced
// the same digest with the candidate grid's own ceiling dropped to zero, i.e.
// with the bucket path never taken at all. Its fixtures are also tiny (6 verts
// / 0 faces, 4/1, 6/1, 8/6, 8/2): on six faces a screen-space grid returns all
// six, so an arithmetic mistake in the cell index cannot show up there either.
//
// This corpus freezes the MASK — the `bool[]` `Mesh.visibleVertices` returns —
// which is the quantity the broad phase must leave bit-identical, and it does
// it on meshes dense enough for a bucket to exclude something.
//
// HOW IT IS USED. Set `VIBE3D_VIS_CORPUS_OUT` to a path and the sweep writes
// the dump there; without it the ordinary gate run computes the same bytes,
// hashes them, and asserts the corpus is NON-VACUOUS, touching no filesystem.
// Capture before a refactor, capture after, `cmp`. That comparison is the
// deliverable; this file is the instrument.
//
// WHY THE DIGEST IS NOT FROZEN IN THE TREE. The mask's arithmetic is float
// (projection) over double (the ray/plane depth gate), and dmd / ldc / a
// different `-O` may legitimately differ in the last bit of a projection near a
// polygon boundary. A frozen digest would be a cross-compiler tripwire, not a
// regression test. What IS asserted on every machine is that the corpus
// reaches the clauses it claims to: each of the five gets its own counter and
// its own assertion, because a corpus that stopped reaching one would keep
// comparing byte-identical against its own silence (task 0635).
//
// THE PATH COUNTERS ARE THE POINT, and they are separate from the clause
// counters on purpose. All five clause counters take IDENTICAL values on the
// linear walk and on a bucketed broad phase — that is what the superset
// contract MEANS — so not one of them can witness which arm ran. `gridQueries`
// / `linearQueries` can, and each fixture declares the arm it expects rather
// than contributing to a total: a fixture whose expected path is not asserted
// is a fixture that proves nothing.
module tests.unit.snap_visibility_corpus_test;

import std.math : PI, sin, sqrt;
import math : Vec3, Viewport, ModelSpace, lookAt, perspectiveMatrix,
              orthographicMatrix;
import mesh : Mesh, makeGridPlane, makeCube, subdivideCube, g_visCounters;

// ---------------------------------------------------------------------------
// The dump format: one line per case, `key|nVerts|<mask as hex nibbles>`.
// Text so a diff names the case that moved rather than a byte offset; the mask
// packed four vertices to a hex digit so a 2401-vertex sheet is one line.
// ---------------------------------------------------------------------------
private string maskLine(string key, const bool[] vis) {
    import std.array  : appender;
    import std.format : format;
    auto a = appender!string();
    a.put(format("%s|%d|", key, vis.length));
    uint acc = 0;
    size_t bit = 0;
    foreach (b; vis) {
        if (b) acc |= (1u << (bit & 3));
        if ((++bit & 3) == 0) { a.put(format("%x", acc)); acc = 0; }
    }
    if (bit & 3) a.put(format("%x", acc));
    a.put("\n");
    return a.data;
}

// ---------------------------------------------------------------------------
// THE FIXTURES. A census, not a set of examples: each one closes a clause the
// others cannot reach, and the comment on each says which.
// ---------------------------------------------------------------------------

// A dense sheet that REALLY occludes itself. A FLAT sheet does not, at any
// angle: its candidate vertices lie IN the plane of every one of its faces, so
// the ray/plane solve puts the hit exactly on the candidate and clause 1 (the
// coincidence exemption) fires before the depth compare — which is precisely
// why the perf fixture reports `0 rejected` and why one flat sheet
// discriminates nothing. Corrugating it puts crests in front of troughs, and
// at a grazing angle a large fraction of the mesh is genuinely behind
// something. 48 quads per side = 2401 verts / 2304 faces — dense enough that a
// screen bucket returns a small fraction of the front list.
private Mesh corrugatedSheet() {
    auto m = makeGridPlane(48);
    foreach (ref v; m.vertices)
        v.y = 0.22f * sin(3.0f * cast(float)PI * v.x);
    return m;
}

// A closed dense solid: every back-facing face is ALSO occluded, so this
// fixture cannot separate the facing term from the depth term — it is here for
// the opposite reason, as the shape on which the two agree, and because a
// subdivided cube is the only fixture where an occluder sits at a large screen
// distance from most of the front list.
private Mesh denseSolid() { return subdivideCube(4); }

// TWO nested sheets: a small dense one INSIDE a large one, so the occluder of
// any given candidate is a handful of faces while the front list is thousands.
// This is the fixture on which a broad phase that quietly returns EVERY
// occluder (or NONE) is still bit-identical on the mask but wildly different
// in pairs tested — and the one M12 (through-path returns an empty occluder
// list) has to redden.
private Mesh nestedGrids() {
    Mesh m = corrugatedSheet();
    auto inner = makeGridPlane(12);
    immutable uint base = cast(uint)m.vertices.length;
    foreach (ref v; inner.vertices)
        m.vertices ~= Vec3(v.x * 0.30f, v.y + 0.55f, v.z * 0.30f);
    foreach (ref f; inner.faces) {
        uint[] nf;
        foreach (vi; f) nf ~= base + vi;
        m.addFace(nf);
    }
    m.buildLoops();
    return m;
}

// One face whose screen bbox covers the WHOLE viewport, in front of a dense
// sheet. Its bbox overlaps every cell of the domain, so it is the fixture that
// says whether the domain clip (Ф3.2) is applied at the right rectangle: clip
// one cell too tight and the candidates near the edge stop seeing it.
private Mesh screenFillingFace() {
    Mesh m = corrugatedSheet();
    immutable uint b = cast(uint)m.vertices.length;
    // A HEXAGON, not a quad, and that is the second thing this fixture buys.
    // The sheet is all quads, so with a quad occluder every ring is 4 long and
    // the shared corner scratch is exactly `face.length` for every face — M11
    // (pass the WHOLE scratch to `pointInPolygon2D` instead of the
    // `[0 .. face.length]` slice) is then a no-op and comes back GREEN, which
    // is a corpus that cannot see the bug rather than a bug that is not there
    // (measured). Six corners make the scratch longer than a quad ring, so a
    // quad tested after the hexagon would close its ring through two of the
    // hexagon's leftover corners and answer a different question.
    // Sized so EVERY corner projects from every camera in the sweep. The
    // first version reached out to +-9 and its corners fell behind the `close`
    // camera, so the `allValid` filter dropped the whole face and the fixture
    // silently stopped being a mixed-ring one at all.
    m.vertices ~= Vec3(-2.50f, 1.20f,  0.00f);
    m.vertices ~= Vec3(-1.25f, 1.20f, -2.20f);
    m.vertices ~= Vec3( 1.25f, 1.20f, -2.20f);
    m.vertices ~= Vec3( 2.50f, 1.20f,  0.00f);
    m.vertices ~= Vec3( 1.25f, 1.20f,  2.20f);
    m.vertices ~= Vec3(-1.25f, 1.20f,  2.20f);
    m.addFace([b, b + 5, b + 4, b + 3, b + 2, b + 1]);
    m.addFace([b, b + 1, b + 2, b + 3, b + 4, b + 5]);   // both windings
    m.buildLoops();
    return m;
}

// A sheet pushed hard to the upper-left, so a large part of it projects to
// NEGATIVE window pixels. This is the only configuration in which the cell
// index of a probed pixel is negative and the sign/floor arithmetic is
// actually exercised — and, with the domain padded around the viewport, the
// only one where a candidate just off the left/top edge still resolves to a
// bucket instead of falling through to the linear walk.
private Mesh borderSheet() {
    Mesh m = corrugatedSheet();
    foreach (ref v; m.vertices) v = v + Vec3(-1.35f, 0, -1.35f);
    return m;
}

// A sheet moved so far off-axis that MOST of what it owns projects outside the
// padded domain. This is the CLIPPING fixture: the mask must be unchanged and
// the linear arm must carry the great majority of the probes (asserted by
// ratio below, not by a bare `mixed`).
//
// "Most", not "all", and the correction is worth keeping: at -14 it still put
// 1323 probes on the grid arm, and pushing it to -40 barely moved that (1196).
// A large plane seen at a grazing angle projects TOWARD ITS VANISHING POINT,
// which is on screen no matter how far along the plane the geometry is — so
// "translate it until nothing lands in the viewport" is not reachable by
// translation at all. The ratio assertion says what the fixture can actually
// promise.
//
// Its second half is M17's target — a broad phase that inserts faces whose
// clipped bbox is empty piles them into the border cells instead.
// A dense sheet parked so that its BULK sits beyond the left edge of the
// padded domain while a thin strip of it still lands ON the border cells.
// It was built FOR mutation M17 — a broad phase that inserts a face whose
// clipped box is empty clamps every off-domain face onto the border column,
// and the candidates in that column then walk all of them — and IT DOES NOT
// WITNESS IT. Measured: M17 moves this fixture's pair count by 54 out of
// 8 573 585 (0.0006%), and the `outside` sheet's by 0. The plan predicted an
// order of magnitude. The reason is geometric: the clamped faces all land in
// ONE border cell, and the in-domain candidates of a sheet parked off to the
// side are spread over the domain rather than sitting in that cell.
//
// The guard stays — the pileup it prevents is bounded only by the face count,
// so a camera that does put the candidates in the border cell pays F extra
// tests per candidate — but it is recorded here as an UNWITNESSED guard
// rather than left looking tested. The fixture stays too: it is the corpus's
// heaviest user of the linear arm (8 181 of its 11 840 probes).
private Mesh borderPileSheet() {
    Mesh m = corrugatedSheet();
    foreach (ref v; m.vertices) v = v + Vec3(-3.60f, 0, 0);
    return m;
}

private Mesh outsideDomainSheet() {
    Mesh m = corrugatedSheet();
    foreach (ref v; m.vertices) v = v + Vec3(-40.0f, 0, 0);
    return m;
}

// A quad with one enormous edge: one endpoint sits where the rest of the mesh
// is, the other hundreds of pixels away. `snap.d`'s `edgeVisible` asks about
// BOTH endpoints of an edge it found near the cursor, so the far endpoint is a
// probe at a pixel the cursor's neighbourhood never covers — the reason the
// linear arm of Ф3.4 is LIVE in the editor and not a dead backstop.
private Mesh longEdgeMesh() {
    Mesh m = corrugatedSheet();
    immutable uint b = cast(uint)m.vertices.length;
    m.vertices ~= Vec3( 0.0f,  0.35f,  0.0f);
    m.vertices ~= Vec3( 9.0f,  0.35f,  0.2f);
    m.vertices ~= Vec3( 9.0f,  0.35f,  0.4f);
    m.vertices ~= Vec3( 0.0f,  0.35f,  0.2f);
    m.addFace([b, b + 3, b + 2, b + 1]);
    m.buildLoops();
    return m;
}

// Vertices BEHIND the eye, and — the half that matters — a LARGE face with
// exactly ONE corner behind it, sitting between the eye and a dense sheet.
//
// That face SEEDS its corners visible (the seed loop runs before the
// all-corners-valid filter) but must never OCCLUDE, because a screen-space
// polygon test on a corner that has no screen position is meaningless: the
// unset corner reads (0, 0), which is a real pixel, so the polygon silently
// becomes a different shape covering a different part of the screen.
//
// THE FIRST VERSION OF THIS FIXTURE WAS TWELVE VERTICES AND PROVED NOTHING.
// M5 (drop the `allValid` filter) came back GREEN on it: the distorted
// polygon has to actually CONTAIN some candidate's pixel before admitting it
// changes an answer, and on twelve vertices spread over the view it contained
// none. The dense sheet behind the straddling quad is what gives the
// distortion something to cover.
private Mesh straddlingMesh() {
    Mesh m = corrugatedSheet();
    immutable uint b = cast(uint)m.vertices.length;
    // A vertical quad between the `close` camera (eye z = 3) and the sheet,
    // covering the -X half of it. Corner b+1 sits at z = 5.2, BEHIND that eye.
    m.vertices ~= Vec3(-2.0f, -2.0f, 1.5f);   // b+0
    m.vertices ~= Vec3(-2.0f,  2.0f, 5.2f);   // b+1  behind the close camera
    m.vertices ~= Vec3( 0.0f,  2.0f, 1.5f);   // b+2
    m.vertices ~= Vec3( 0.0f, -2.0f, 1.5f);   // b+3
    m.addFace([b, b + 1, b + 2, b + 3]);
    m.addFace([b + 3, b + 2, b + 1, b]);      // the other winding, so one of
                                              // the pair faces every camera
    // A face EVERY corner of which is behind that eye — the `anyValid` drop,
    // a different clause from the one above.
    m.vertices ~= Vec3(-0.2f,  0.9f, 7.5f);
    m.vertices ~= Vec3( 0.2f,  0.9f, 7.5f);
    m.vertices ~= Vec3( 0.2f,  1.2f, 7.5f);
    m.vertices ~= Vec3(-0.2f,  1.2f, 7.5f);
    m.addFace([b + 4, b + 5, b + 6, b + 7]);
    m.buildLoops();
    return m;
}

// TWO duties of the hidden-face skip, on one fixture, because each is
// invisible without the other's shape:
//
//   * a hidden face in the MIDDLE of a surface must not SEED — except that
//     every one of its corners also touches three visible faces, so on that
//     shape alone the skip changes nothing and M3 stays GREEN (measured);
//   * a hidden face BETWEEN the eye and a dense sheet must not OCCLUDE, and
//     its own four corners, which belong to no other face, must not be seeded
//     visible. That is the half with an observable answer.
private Mesh hiddenMiddleMesh() {
    Mesh m = corrugatedSheet();
    immutable uint b = cast(uint)m.vertices.length;
    // A lid over the +X half of the sheet, above it in Y, and its mirror
    // below — so one of the pair is front-facing from every camera here.
    m.vertices ~= Vec3( 0.05f, 0.62f, -1.10f);
    m.vertices ~= Vec3( 1.10f, 0.62f, -1.10f);
    m.vertices ~= Vec3( 1.10f, 0.62f,  1.10f);
    m.vertices ~= Vec3( 0.05f, 0.62f,  1.10f);
    m.addFace([b, b + 3, b + 2, b + 1]);
    m.addFace([b, b + 1, b + 2, b + 3]);
    m.buildLoops();
    // `setFaceHidden` is bounds-guarded against `faceMarks`, which the
    // factories leave un-sized — hide without this line and the call is a
    // silent no-op, which is exactly how a fixture goes inert.
    m.resizeFaceSelection();
    immutable size_t lidA = m.faces.length - 2, lidB = m.faces.length - 1;
    m.setFaceHidden(lidA, true);
    m.setFaceHidden(lidB, true);
    m.setFaceHidden(48 * 3 + 3, true);   // an interior quad of the sheet
    assert(m.isFaceHidden(lidA) && m.isFaceHidden(lidB) && m.isFaceHidden(48 * 3 + 3),
        "fixture: the hidden faces must actually be marked Hide");
    return m;
}

// The facing law's two hard shapes, side by side (CLAUDE.md, task 0832):
//   * a SPLIT face whose ring starts at the midpoint an edge split left, so
//     the corner triangle at ring index 0 is degenerate and its normal is
//     EXACTLY zero — the polygon that is lassoable and snappable from both
//     sides, and the reason the cull is a strict `> 0`;
//   * a REFLEX-FIRST ring, whose corner-triangle normal is turned 180 degrees
//     against Newell's.
// M4 (swap `frontFacingLocal` for the Newell face normal) has to redden here.
private Mesh facingLawMesh() {
    Mesh m;
    m.vertices = [
        // split quad: ring starts at the collinear midpoint of its first edge
        Vec3(-1.5f, 0.0f, -0.5f),   // 0  midpoint (ring index 0)
        Vec3(-1.0f, 0.0f, -0.5f),   // 1
        Vec3(-1.0f, 0.0f,  0.5f),   // 2
        Vec3(-2.0f, 0.0f,  0.5f),   // 3
        Vec3(-2.0f, 0.0f, -0.5f),   // 4
        // reflex-first L, ring starting at the reflex corner
        Vec3( 0.5f, 0.0f,  0.0f),   // 5  reflex (ring index 0)
        Vec3( 0.5f, 0.0f, -0.8f),   // 6
        Vec3( 1.6f, 0.0f, -0.8f),   // 7
        Vec3( 1.6f, 0.0f,  0.8f),   // 8
        Vec3(-0.1f, 0.0f,  0.8f),   // 9
        Vec3(-0.1f, 0.0f,  0.0f),   // 10
        // a plain occluder above both, so the depth gate has something to do
        Vec3(-2.2f, 0.6f, -0.9f),   // 11
        Vec3( 1.8f, 0.6f, -0.9f),   // 12
        Vec3( 1.8f, 0.6f,  0.9f),   // 13
        Vec3(-2.2f, 0.6f,  0.9f),   // 14
    ];
    m.addFace([0u, 1u, 2u, 3u, 4u]);
    m.addFace([5u, 6u, 7u, 8u, 9u, 10u]);
    m.addFace([11u, 14u, 13u, 12u]);
    m.buildLoops();
    return m;
}

// ONE face, wound AWAY from the eye, with nothing in front of it. Nothing can
// occlude here, so the SEED term is the only thing that separates "not
// visible" from "visible" — M6 (drop the seed from the per-vertex answer)
// reddens on this fixture and on no other.
private Mesh awayQuad() {
    Mesh m;
    m.vertices = [
        Vec3(-0.8f, -0.8f, 0.0f), Vec3(0.8f, -0.8f, 0.0f),
        Vec3( 0.8f,  0.8f, 0.0f), Vec3(-0.8f, 0.8f, 0.0f),
    ];
    m.addFace([0u, 3u, 2u, 1u]);   // clockwise from +Z, i.e. away from a +Z eye
    m.buildLoops();
    return m;
}

// ---------------------------------------------------------------------------
// The query pad is a numeric that SCALES the bucket grid's domain, and it
// arrives from a Param with no declared bounds. These are the values a Param
// can actually deliver — NaN and +inf from a parse, a huge finite one from a
// typed entry — and the contract is that each produces the SAME mask as the
// default, because the pad only ever decides which arm answers a probe.
// Without this, the clamp is a line nobody executes.
// ---------------------------------------------------------------------------
unittest {
    import std.format : format;
    auto m = corrugatedSheet();
    Viewport vp;
    vp.eye = Vec3(2.2f, 0.32f, 1.4f);
    vp.view = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
    vp.proj = perspectiveMatrix(PI / 4, 4.0f / 3.0f, 0.01f, 100.0f);
    vp.width = 1280; vp.height = 960;

    bool[] refMask = m.visibleVertices(vp.eye, vp, ModelSpace.world());
    bool any = false;
    foreach (b; refMask) if (b) { any = true; break; }
    assert(any, "fixture: the reference mask must not be all-false");

    static immutable float[] pads = [
        0.0f, 80.0f, 4096.0f, 1.0e30f, -50.0f,
        float.nan, float.infinity, -float.infinity,
    ];
    foreach (pad; pads) {
        auto probe = m.visibilityProbe(vp.eye, vp, ModelSpace.world(), pad);
        foreach (vi; 0 .. m.vertices.length)
            assert(probe.visible(vi) == refMask[vi],
                format("query pad %s changed the mask at vertex %d", pad, vi));
    }
}

// ---------------------------------------------------------------------------
// THE EXPECTED PATH, per fixture.
//
// `grid` = every probe resolved to a bucket; `linear` = every probe walked the
// whole front list; `mixed` = both arms ran; `none` = pass 2 never ran at all,
// which is a REAL state and not an omission — on a mesh whose every face is
// back-facing nothing is seeded, so no candidate ever reaches the occluder
// walk. Stated per fixture and asserted per fixture: a SUM over the corpus
// would be satisfied by one fixture taking the grid arm and would say nothing
// about the other ten.
// ---------------------------------------------------------------------------
private enum Path { grid, linear, mixed, none }

unittest {
    import std.array   : appender;
    import std.format  : format;
    import std.process : environment;
    import std.stdio   : stderr;

    static struct Fixture { string name; Mesh* m; Path expect; }

    Mesh* heap(Mesh v) { Mesh* p = new Mesh; *p = v; return p; }

    // MEASURED, not predicted, and that is the point of stating it per
    // fixture: before Ф3 every entry read `linear`, because there was only one
    // arm. The flip in this table IS the evidence that the bucket path is
    // reached where it should be — no clause counter can say so, since all of
    // them take identical values on both arms by the superset contract.
    Fixture[] fixtures = [
        Fixture("corrugated",  heap(corrugatedSheet()),     Path.grid),
        Fixture("densesolid",  heap(denseSolid()),          Path.grid),
        Fixture("nested",      heap(nestedGrids()),         Path.grid),
        Fixture("screenfill",  heap(screenFillingFace()),   Path.mixed),
        Fixture("border",      heap(borderSheet()),         Path.mixed),
        Fixture("outside",     heap(outsideDomainSheet()),  Path.mixed ),
        Fixture("borderpile",  heap(borderPileSheet()),     Path.mixed ),
        Fixture("longedge",    heap(longEdgeMesh()),        Path.mixed),
        Fixture("straddling",  heap(straddlingMesh()),      Path.mixed),
        Fixture("hiddenmid",   heap(hiddenMiddleMesh()),    Path.grid),
        Fixture("facinglaw",   heap(facingLawMesh()),       Path.mixed),
        Fixture("awayquad",    heap(awayQuad()),            Path.none),
    ];

    // --- the cameras -------------------------------------------------------
    //
    // `grazing` is the one that makes the corrugated sheet occlude itself;
    // `offsetvp` carries a NON-ZERO viewport origin (the editor's real docked
    // layout, vpX=150 vpY=28), which is a separate clause from the negative
    // pixel one — an implementation can get the domain right and the origin
    // offset wrong, and only this camera says so; `close` puts geometry behind
    // the eye plane.
    static struct Cam { string name; Viewport vp; }
    Cam[] cams;
    {
        Viewport vp;
        vp.eye = Vec3(0.0f, 2.4f, 0.05f);
        vp.view = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 0, -1));
        vp.proj = perspectiveMatrix(PI / 4, 4.0f / 3.0f, 0.01f, 100.0f);
        vp.width = 640; vp.height = 480;
        cams ~= Cam("above", vp);
    }
    {
        Viewport vp;
        vp.eye = Vec3(2.2f, 0.32f, 1.4f);
        vp.view = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
        vp.proj = perspectiveMatrix(PI / 4, 4.0f / 3.0f, 0.01f, 100.0f);
        vp.width = 1280; vp.height = 960;
        cams ~= Cam("grazing", vp);
    }
    {
        Viewport vp;
        vp.eye = Vec3(1.324741f, -1.168255f, 2.424921f);   // the perf camera
        vp.view = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
        vp.proj = perspectiveMatrix(PI / 4, 4.0f / 3.0f, 0.001f, 100.0f);
        vp.width = 1280; vp.height = 960;
        vp.x = 150; vp.y = 28;
        cams ~= Cam("offsetvp", vp);
    }
    {
        Viewport vp;
        vp.eye = Vec3(0.15f, 0.10f, 3.0f);
        vp.view = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
        vp.proj = perspectiveMatrix(PI / 2, 1.0f, 0.05f, 100.0f);
        vp.width = 400; vp.height = 400;
        cams ~= Cam("close", vp);
    }
    {
        Viewport vp;
        vp.eye = Vec3(0, 0, 6.0f);
        vp.view = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
        vp.proj = orthographicMatrix(1.5f, 4.0f / 3.0f, 0.1f, 100.0f);
        vp.width = 640; vp.height = 480;
        cams ~= Cam("ortho", vp);
    }

    // --- the model spaces --------------------------------------------------
    ModelSpace mirrorX;
    mirrorX.m          = [-1,0,0,0,  0,1,0,0,  0,0,1,0,  0,0,0,1];
    mirrorX.mInv       = mirrorX.m;          // diag(-1,1,1) is its own inverse
    mirrorX.isIdentity = false;
    mirrorX.invertible = true;
    mirrorX.mirrored   = true;
    static struct Space { string name; ModelSpace ms; }
    Space[] spaces = [Space("id", ModelSpace.world()), Space("mirrorx", mirrorX)];

    // --- the sweep ---------------------------------------------------------
    auto dump = appender!string();
    size_t cases = 0;
    long trueBits = 0, falseBits = 0;

    long[] perFixtureGrid, perFixtureLinear, perFixturePairs;

    g_visCounters.reset();
    foreach (ref f; fixtures) {
        immutable long gridBefore   = g_visCounters.gridQueries;
        immutable long linearBefore = g_visCounters.linearQueries;
        immutable long pairsBefore  = g_visCounters.pairsTested;
        foreach (ref cm; cams) {
            foreach (ref sp; spaces) {
                bool[] vis = f.m.visibleVertices(cm.vp.eye, cm.vp, sp.ms);
                dump.put(maskLine(format("%s/%s/%s", f.name, cm.name, sp.name), vis));
                ++cases;
                foreach (b; vis) { if (b) ++trueBits; else ++falseBits; }
            }
        }
        perFixtureGrid   ~= g_visCounters.gridQueries   - gridBefore;
        perFixtureLinear ~= g_visCounters.linearQueries - linearBefore;
        perFixturePairs  ~= g_visCounters.pairsTested   - pairsBefore;
    }

    // --- the digest, and the file, BEFORE any assertion ---------------------
    //
    // Written first on purpose: a mutation that trips one of the assertions
    // below would otherwise leave no artefact to diff, and "the test threw"
    // says less than "the test threw AND these twelve cases moved".
    immutable string text = dump.data;
    ulong h = 0xcbf29ce484222325UL;
    foreach (ubyte ub; cast(const(ubyte)[])text) { h ^= ub; h *= 0x100000001b3UL; }
    immutable string outPath = environment.get("VIBE3D_VIS_CORPUS_OUT", "");
    if (outPath.length) {
        import std.file : write;
        write(outPath, text);
    }
    stderr.writefln("snap visibility corpus: %d bytes, fnv1a=%016x%s",
                    text.length, h, outPath.length ? " -> " ~ outPath : "");

    stderr.writefln("snap visibility corpus: %d cases | occluded=%d seedFalse=%d "
                  ~ "invalidProj=%d hiddenSkip=%d anyValidSkip=%d allValidSkip=%d "
                  ~ "grid=%d linear=%d gridOutsideVp=%d gridNegPixel=%d pairs=%d",
                    cases, g_visCounters.occluded, g_visCounters.seedFalse,
                    g_visCounters.invalidProj, g_visCounters.hiddenSkip,
                    g_visCounters.anyValidSkip, g_visCounters.allValidSkip,
                    g_visCounters.gridQueries, g_visCounters.linearQueries,
                    g_visCounters.gridOutsideVp, g_visCounters.gridNegPixel,
                    g_visCounters.pairsTested);
    foreach (i, ref f; fixtures)
        stderr.writefln("  %-12s expect=%-6s grid=%-9d linear=%-9d pairs=%-12d",
                        f.name, f.expect, perFixtureGrid[i], perFixtureLinear[i],
                        perFixturePairs[i]);

    // --- the per-fixture PATH assertions -----------------------------------
    foreach (i, ref f; fixtures) {
        immutable long gridHere = perFixtureGrid[i], linearHere = perFixtureLinear[i];
        final switch (f.expect) {
            case Path.grid:
                assert(gridHere > 0 && linearHere == 0,
                    format("%s: expected the BUCKET path only, got grid=%d linear=%d",
                           f.name, gridHere, linearHere));
                break;
            case Path.linear:
                assert(linearHere > 0 && gridHere == 0,
                    format("%s: expected the LINEAR path only, got grid=%d linear=%d",
                           f.name, gridHere, linearHere));
                break;
            case Path.mixed:
                assert(gridHere > 0 && linearHere > 0,
                    format("%s: expected BOTH paths, got grid=%d linear=%d",
                           f.name, gridHere, linearHere));
                break;
            case Path.none:
                assert(gridHere == 0 && linearHere == 0,
                    format("%s: expected pass 2 never to run, got grid=%d linear=%d",
                           f.name, gridHere, linearHere));
                break;
        }
    }

    // The CLIPPING fixture, by ratio. `mixed` alone would be satisfied by one
    // stray probe on either arm; what this fixture claims is that the linear
    // arm carries the bulk of it.
    foreach (i, ref f; fixtures)
        if (f.name == "outside")
            assert(perFixtureLinear[i] > 4 * perFixtureGrid[i],
                format("outside: expected the linear arm to dominate, got "
                     ~ "grid=%d linear=%d", perFixtureGrid[i], perFixtureLinear[i]));

    // --- the vacuity assertions -------------------------------------------
    //
    // Five clauses, five counters, five separate messages: a zero has to say
    // WHICH clause went quiet, not "something did".
    assert(cases > 100, format("corpus too small to be a corpus: %d cases", cases));
    assert(trueBits  > 0, "no vertex was ever visible — every fixture is off-screen");
    assert(falseBits > 0, "no vertex was ever hidden — the mask never says no");
    assert(g_visCounters.occluded > 0,
        "no vertex was ever OCCLUDED: every fixture is a flat sheet or a "
        ~ "point cloud, and the depth gate is untested");
    assert(g_visCounters.seedFalse > 0,
        "no vertex was ever left UNSEEDED: the facing term is untested");
    assert(g_visCounters.invalidProj > 0,
        "no vertex ever failed to project: the behind-the-camera clause is untested");
    assert(g_visCounters.hiddenSkip > 0,
        "no face was ever skipped as HIDDEN: `isFaceHidden` is untested");
    assert(g_visCounters.anyValidSkip > 0,
        "no face was ever dropped with EVERY corner behind the eye");
    // The two clauses the query PAD buys. Without them, dropping the pad
    // (mutation M15) leaves the mask identical and merely moves a few probes
    // from one arm to the other — i.e. it is unobservable, which is the same
    // as untested.
    assert(g_visCounters.gridOutsideVp > 0,
        "no probe outside the viewport rectangle was ever answered from a "
        ~ "bucket: the query pad is doing nothing this corpus can see");
    assert(g_visCounters.gridNegPixel > 0,
        "no probe at a NEGATIVE window pixel was ever answered from a bucket: "
        ~ "the signed cell-index arithmetic is untested");
    assert(g_visCounters.allValidSkip > 0,
        "no face was ever dropped for SOME corner behind the eye: seed-set and "
        ~ "occluder-set are indistinguishable in this corpus");
}
