// Hide Geometry — Stage 5 (doc/hide_geometry_plan.md §3.2/§3.3, §6 S5):
// OPERATIONS DO NOT SEE HIDDEN GEOMETRY.
//
// S5 routed the "empty selection ⇒ operate on the whole mesh" convention —
// implemented across the tree in FIVE structurally different shapes — into one
// funnel (Mesh.operand{Vertex,Edge,Face}Mask) whose fallback branch means
// "every VISIBLE element". This file drives that through the real command and
// tool paths and asserts the resulting GEOMETRY, not a status code.
//
// ---------------------------------------------------------------------------
// THE ORACLE, and why it is not vacuous
// ---------------------------------------------------------------------------
// Most rows below use one oracle: for the same operation,
//
//     hide the complement + run with an EMPTY selection
//         must produce byte-identical geometry to
//     select the visible faces + run with nothing hidden
//
// The two runs take genuinely different code paths — the first goes through
// the fallback branch of the funnel, the second through the selection branch —
// so agreement is a real measurement, not a tautology. And a wrong
// implementation is loud: one that ignores hiding operates on all 6 cube faces
// and produces a mesh with a different vertex and face count from one that
// operated on 3. Where an operation's arithmetic is simple enough to predict,
// the row asserts the absolute number TOO, so "the two runs agree" can never
// be satisfied by both of them being wrong in the same way.
//
// ---------------------------------------------------------------------------
// FIXTURE CHOICE (the trap Stage 4 hit)
// ---------------------------------------------------------------------------
// makeCube()'s faces are
//   f0=[0,3,2,1] f1=[4,5,6,7] f2=[0,4,7,3] f3=[1,2,6,5] f4=[3,7,6,2] f5=[0,1,5,4]
// with opposite pairs (f0,f1) (f2,f3) (f4,f5). Two hidden sets are used, and
// the difference between them IS the measured per-component law (§1.2):
//   * HIDE_FACES = {0,1,2} — hides NO vertex (every corner still touches a
//     visible face), so it isolates the FACE plane. Asymmetric, as §7 requires.
//   * HIDE_CORNER = {0,2,5} — vertex 0's three incident faces, and ONLY
//     vertex 0 derives hidden. Its neighbours v1/v3/v4 stay VISIBLE, so no
//     pre-existing check can do the new code's work for it.
//
// ---------------------------------------------------------------------------
// STATED GAP
// ---------------------------------------------------------------------------
// The plan's T-S5c specifies "run a whole-mesh MOVE". There is no such thing
// to drive here: `commands/mesh/transform.d` builds its vertex mask with NO
// whole-mesh fallback branch at all (the plan's §3.2 lists it under "looks
// like a leak and is not"), so `mesh.transform` on an empty selection moves
// nothing and could not discriminate any implementation from any other. The
// whole-mesh move path is the interactive gizmo, which consumes
// `Mesh.selectedVertexIndices*` (§3.2 shape A) — that accessor family is
// pinned by unittests in source/mesh.d asserting the same 8-vs-7 numbers T-S5c
// calls for. What is NOT covered anywhere is an end-to-end gizmo DRAG with
// something hidden; it needs an event-log fixture and is left to S7.

import http_client : testBaseUrl, getJson, postJson;
import std.net.curl;
import std.json;
import std.conv : to;
import std.math : fabs;
import std.algorithm : sort, canFind;
import std.string : format;

void main() {}

alias baseUrl = testBaseUrl;


void cmd(string s) {
    auto j = postJson("/api/command", s);
    assert(j["status"].str == "ok", "cmd `" ~ s ~ "` failed: " ~ j.toString);
}

void resetCube() {
    auto r = postJson("/api/reset", "");
    assert(r["status"].str == "ok", "/api/reset failed: " ~ r.toString);
    cmd(`{"id":"history.clear"}`);
}

JSONValue model() { return getJson("/api/model"); }

void selectFaces(int[] idx) {
    cmd("select.typeFrom polygon");
    string j = "[";
    foreach (i, v; idx) { if (i) j ~= ","; j ~= v.to!string; }
    j ~= "]";
    auto r = postJson("/api/select", `{"mode":"polygons","indices":` ~ j ~ `}`);
    assert(r["status"].str == "ok", "/api/select failed: " ~ r.toString);
}

void selectVertices(int[] idx) {
    cmd("select.typeFrom vertex");
    string j = "[";
    foreach (i, v; idx) { if (i) j ~= ","; j ~= v.to!string; }
    j ~= "]";
    auto r = postJson("/api/select", `{"mode":"vertices","indices":` ~ j ~ `}`);
    assert(r["status"].str == "ok", "/api/select failed: " ~ r.toString);
}

// Hide `idx` and leave the mesh with an EMPTY selection — which is what makes
// the whole-mesh fallback fire on the next command. The empty-selection
// postcondition is asserted, not assumed: §3.1's Select ∧ Hide = ∅ is what
// produces it, and if that ever regressed every row below would silently start
// measuring the selection branch instead of the fallback.
void hideFaces(int[] idx) {
    selectFaces(idx);
    cmd(`{"id":"mesh.hide"}`);
    auto hid = faceHidden();
    foreach (i; idx)
        assert(hid[i], "fixture: face " ~ i.to!string ~ " should be hidden");
    size_t n = 0; foreach (b; hid) if (b) ++n;
    assert(n == idx.length, "fixture: expected " ~ idx.length.to!string
        ~ " hidden faces, got " ~ n.to!string);
    auto sel = getJson("/api/selection");
    assert(sel["selectedFaces"].array.length == 0,
        "fixture: hiding must leave an EMPTY selection, else these rows would "
        ~ "measure the selection branch and not the whole-mesh fallback");
}

bool[] faceHidden() {
    bool[] r;
    foreach (b; model()["faceHidden"].array) r ~= b.type == JSONType.true_;
    return r;
}

bool[] vertexHidden() {
    bool[] r;
    foreach (b; model()["vertexHidden"].array) r ~= b.type == JSONType.true_;
    return r;
}

double[3][] verts(JSONValue m) {
    double[3][] r;
    foreach (v; m["vertices"].array) {
        auto a = v.array;
        r ~= [a[0].floating, a[1].floating, a[2].floating];
    }
    return r;
}

int[][] faces(JSONValue m) {
    int[][] r;
    foreach (f; m["faces"].array) {
        int[] fv;
        foreach (v; f.array) fv ~= cast(int) v.integer;
        r ~= fv;
    }
    return r;
}

// A comparable, order-preserving digest of the geometry (positions + face
// rings). Positions are rounded to 1e-6 so float formatting cannot make two
// identical meshes look different.
string geom(JSONValue m) {
    string s;
    foreach (v; verts(m))
        s ~= format("%.6f,%.6f,%.6f;", v[0], v[1], v[2]);
    s ~= "|";
    foreach (f; faces(m)) {
        foreach (v; f) s ~= v.to!string ~ ",";
        s ~= ";";
    }
    return s;
}

bool near(double a, double b, double eps = 1e-6) { return fabs(a - b) < eps; }

// The untouched cube's digest, so every oracle row can prove the operation it
// is comparing actually DID something. Without this an operation that no-ops
// (a mistyped attr name, an unmet precondition) makes the hide-vs-select
// comparison compare two identical untouched meshes and pass while measuring
// nothing at all.
string pristineGeom() {
    resetCube();
    return geom(model());
}

void assertDidSomething(string label, JSONValue after) {
    static string pristine;
    if (pristine.length == 0) pristine = pristineGeom();
    assert(geom(after) != pristine,
        label ~ ": the operation left the cube untouched, so this row's "
        ~ "hide-vs-select comparison would pass while measuring nothing. "
        ~ "Check the command id and its attr names.");
}

enum int[] HIDE_FACES  = [0, 1, 2];   // hides no vertex — isolates the face plane
enum int[] SHOW_FACES  = [3, 4, 5];   // its complement
enum int[] HIDE_CORNER = [0, 2, 5];   // vertex 0's three incident faces

// ---------------------------------------------------------------------------
// T-S5a — the whole-mesh fallback means "all VISIBLE" (shape B, mesh.flip)
//
// mesh.flip changes a per-face value that is readable per face and is NOT a
// count: winding. So "the right 4 flipped and the right 2 did not" is
// checkable face by face, which a count-only assertion could not do.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    auto before = faces(model());

    hideFaces([0, 4]);                 // non-adjacent; index 0 is the low-index trap
    cmd(`{"id":"mesh.flip"}`);

    auto after = faces(model());
    assert(after.length == 6, "flip must not change the face count, got "
        ~ after.length.to!string);

    foreach (fi; 0 .. 6) {
        const hidden = (fi == 0 || fi == 4);
        const same   = after[fi] == before[fi];
        assert(same == hidden,
            "T-S5a: face " ~ fi.to!string ~ (hidden
                ? " is HIDDEN and its winding must be untouched (an unfiltered "
                  ~ "whole-mesh flip reverses all 6)"
                : " is VISIBLE and its winding must have been reversed (a "
                  ~ "blanket refusal reverses none)")
            ~ " — before " ~ before[fi].to!string ~ " after " ~ after[fi].to!string);
    }
}

// ---------------------------------------------------------------------------
// T-S5b — the whole-mesh operand set excludes hidden, across command families
//
// Eight commands from different families, each run twice (see THE ORACLE at
// the top of the file). Rows that have simple arithmetic also assert the
// absolute face count, so the two runs cannot agree by being wrong together.
// ---------------------------------------------------------------------------

private void s5bRow(string command, long expectFaceCount) {
    // (a) hidden complement + empty selection ⇒ the fallback branch
    resetCube();
    hideFaces(HIDE_FACES);
    cmd(command);
    auto viaHide = model();
    // Read the surviving hidden set NOW, while run (a)'s mesh is still live —
    // reading it after run (b) would report run (b)'s state, which has nothing
    // hidden, and the assertion would be measuring the wrong mesh.
    auto hidAfter = faceHidden();

    // (b) explicit selection of the same visible faces ⇒ the selection branch
    resetCube();
    selectFaces(SHOW_FACES);
    cmd(command);
    auto viaSelect = model();

    assertDidSomething("T-S5b [" ~ command ~ "]", viaHide);
    assert(geom(viaHide) == geom(viaSelect),
        "T-S5b [" ~ command ~ "]: the whole-mesh fallback with "
        ~ "faces 0,1,2 hidden must operate on exactly faces 3,4,5 — the "
        ~ "geometry differs from the explicit-selection run.\n  via hide:   "
        ~ geom(viaHide) ~ "\n  via select: " ~ geom(viaSelect));

    if (expectFaceCount >= 0) {
        const got = viaHide["faces"].array.length;
        assert(got == expectFaceCount,
            "T-S5b [" ~ command ~ "]: expected " ~ expectFaceCount.to!string
            ~ " faces when 3 of 6 are operated on, got " ~ got.to!string
            ~ " (an implementation that operates on all 6 reads a different number)");
    }

    // The hidden faces must still be there AND still be hidden: an operation
    // that skipped them geometrically but dropped their Hide bit would pass
    // the oracle above and still lose the user's state.
    size_t stillHidden = 0; foreach (b; hidAfter) if (b) ++stillHidden;
    assert(stillHidden == HIDE_FACES.length,
        "T-S5b [" ~ command ~ "]: expected " ~ HIDE_FACES.length.to!string
        ~ " faces to remain hidden after the op, got " ~ stillHidden.to!string);
}

unittest { // face DELETE — the family whose failure destroys user data
    // 3 visible faces deleted ⇒ the 3 hidden ones survive.
    s5bRow(`{"id":"mesh.delete"}`, 3);
}

unittest { s5bRow(`{"id":"mesh.triple"}`, 3 + 3 * 2); }   // 3 quads kept + 3 tripled quads → 6 tris
unittest { s5bRow(`{"id":"mesh.spikey"}`, -1); }
unittest { s5bRow(`{"id":"mesh.poly_inset"}`, -1); }
unittest { s5bRow(`{"id":"poly.extrude"}`, -1); }   // commands/mesh/face_extrude.d
unittest { s5bRow(`{"id":"mesh.bevel"}`, -1); }
unittest { s5bRow(`{"id":"mesh.smooth_shift"}`, -1); }
// NOT a row: `mesh.quadruple` merges triangle PAIRS into quads, so on an
// all-quad cube it is an exact no-op — `assertDidSomething` caught it comparing
// two untouched cubes and "passing". It would need a tripled fixture to say
// anything, and `mesh.triple` above already covers the same shape-B call site
// family (the mode-gated visibleFaceMask() fallback), so it is dropped rather
// than propped up. Do not re-add it on a cube.

// ---------------------------------------------------------------------------
// T-S5c / T-R2d — the exclusion is PER COMPONENT TYPE (shape D)
//
// Two rows on one deform, and the pair is the assertion: running only row (i)
// would look like a leak, running only row (ii) would look like blanket
// exclusion. mesh.quantize is used because it moves every vertex to a
// COMPUTABLE target, so "7 moved to the right places, 1 untouched" is
// checkable per vertex — with step 0.4, a cube corner at ±0.5 lands on ±0.4.
// ---------------------------------------------------------------------------

// NB: the attrs are X/Y/Z, not stepX/stepY/stepZ. An unknown attr name is
// accepted with status:ok and silently ignored, so the first draft of this
// file ran quantize at its 0.1 default — on a cube whose corners are at ±0.5
// that is an exact no-op, and every oracle row below would have compared two
// untouched cubes and passed. That is what `assertDidSomething` now prevents.
enum string QUANTIZE = "mesh.quantize X:0.4 Y:0.4 Z:0.4";

unittest { // (i) a POLYGON hide freezes no vertex — all 8 move (C8d)
    resetCube();
    auto before = verts(model());
    hideFaces([0, 1]);
    assert(vertexHidden() == [false, false, false, false, false, false, false, false],
        "fixture (i): two polygon hides must derive NO hidden vertex");

    cmd(QUANTIZE);
    auto after = verts(model());
    foreach (vi; 0 .. 8)
        foreach (c; 0 .. 3)
            assert(near(fabs(after[vi][c]), 0.4),
                "T-S5c (i): vertex " ~ vi.to!string ~ " axis " ~ c.to!string
                ~ " must quantise to ±0.4, got " ~ after[vi][c].to!string
                ~ " (a naive 'hidden faces freeze their vertices' rule leaves "
                ~ "4 of the 8 at ±0.5)");
    assert(before.length == after.length);
}

unittest { // (ii) a derived VERTEX hide freezes exactly that vertex (C8e)
    resetCube();
    auto before = verts(model());
    hideFaces(HIDE_CORNER);
    auto vh = vertexHidden();
    assert(vh[0], "fixture (ii): vertex 0 must derive hidden");
    size_t nHidden = 0; foreach (b; vh) if (b) ++nHidden;
    assert(nHidden == 1, "fixture (ii): EXACTLY vertex 0 hides; its neighbours "
        ~ "v1/v3/v4 must stay visible, got " ~ nHidden.to!string ~ " hidden");

    cmd(QUANTIZE);
    auto after = verts(model());

    foreach (c; 0 .. 3)
        assert(after[0][c] == before[0][c],
            "T-S5c (ii): the hidden vertex must be BIT-identical on axis "
            ~ c.to!string ~ ": was " ~ before[0][c].to!string
            ~ " now " ~ after[0][c].to!string
            ~ " (an implementation that ignores hiding moves it to ±0.4)");
    foreach (vi; 1 .. 8)
        foreach (c; 0 .. 3)
            assert(near(fabs(after[vi][c]), 0.4),
                "T-S5c (ii): visible vertex " ~ vi.to!string ~ " must quantise, got "
                ~ after[vi][c].to!string
                ~ " (an implementation that skips the whole command when "
                ~ "anything is hidden leaves all 8 at ±0.5)");
}

private void shapeDRow(string command) {
    // The shape-D funnel again, this time against the selection branch: the
    // 7 visible vertices selected explicitly must give the same result as the
    // empty-selection fallback with vertex 0 derived-hidden.
    resetCube();
    hideFaces(HIDE_CORNER);
    cmd(command);
    auto viaHide = model();

    resetCube();
    selectVertices([1, 2, 3, 4, 5, 6, 7]);
    cmd(command);
    auto viaSelect = model();

    assertDidSomething("T-R2d [" ~ command ~ "]", viaHide);
    assert(geom(viaHide) == geom(viaSelect),
        "T-R2d [" ~ command ~ "]: the vertex-plane fallback must operate on "
        ~ "the 7 VISIBLE vertices.\n  via hide:   " ~ geom(viaHide)
        ~ "\n  via select: " ~ geom(viaSelect));
}

unittest { shapeDRow(QUANTIZE); }
unittest { shapeDRow("mesh.jitter rangeX:0.1 rangeY:0.1 rangeZ:0.1 seed:42"); }
unittest { shapeDRow(`{"id":"mesh.smooth"}`); }
unittest { shapeDRow(`{"id":"mesh.magnet"}`); }

// ---------------------------------------------------------------------------
// T-R2c — the inline FACE-mask fallbacks (shape C): mirror / array / clone /
// radial_array. Four separate copies of one idiom; rev1's lever reached none
// of them, so each gets its own row.
// ---------------------------------------------------------------------------

private void shapeCRow(string command, long expectFaceCount) {
    resetCube();
    hideFaces(HIDE_FACES);
    cmd(command);
    auto viaHide = model();

    resetCube();
    selectFaces(SHOW_FACES);
    cmd(command);
    auto viaSelect = model();

    assertDidSomething("T-R2c [" ~ command ~ "]", viaHide);
    assert(geom(viaHide) == geom(viaSelect),
        "T-R2c [" ~ command ~ "]: the inline face-mask fallback must clone "
        ~ "exactly the 3 VISIBLE faces.\n  via hide:   " ~ geom(viaHide)
        ~ "\n  via select: " ~ geom(viaSelect));

    if (expectFaceCount >= 0) {
        const got = viaHide["faces"].array.length;
        assert(got == expectFaceCount,
            "T-R2c [" ~ command ~ "]: expected " ~ expectFaceCount.to!string
            ~ " faces, got " ~ got.to!string
            ~ " (cloning all 6 sources reads a different number)");
    }
}

unittest { // mirror: 6 originals + 3 mirrored sources = 9 (all 6 would give 12)
    shapeCRow(`{"id":"mesh.mirror","params":{"axis":"X","center":[2,0,0],`
            ~ `"weld":0,"flip_normals":true}}`, 9);
}
unittest { shapeCRow(`{"id":"mesh.clone"}`, -1); }
unittest { shapeCRow(`{"id":"mesh.array"}`, -1); }
unittest { shapeCRow(`{"id":"mesh.radial_array"}`, -1); }

// ---------------------------------------------------------------------------
// T-R2e — the tool `currentMask()` fallbacks (shape E)
//
// Extrusion changes BOTH the face count and the positions, so an
// implementation that extrudes all 6 differs in count AND in the hidden
// faces' geometry — two independent signals.
// ---------------------------------------------------------------------------

private void shapeERow(string toolId, string attr) {
    resetCube();
    hideFaces(HIDE_FACES);
    cmd("tool.set " ~ toolId ~ " on");
    if (attr.length) cmd("tool.attr " ~ toolId ~ " " ~ attr);
    cmd("tool.doApply");
    auto viaHide = model();
    cmd("tool.set " ~ toolId ~ " off");

    resetCube();
    selectFaces(SHOW_FACES);
    cmd("tool.set " ~ toolId ~ " on");
    if (attr.length) cmd("tool.attr " ~ toolId ~ " " ~ attr);
    cmd("tool.doApply");
    auto viaSelect = model();
    cmd("tool.set " ~ toolId ~ " off");

    assertDidSomething("T-R2e [" ~ toolId ~ "]", viaHide);
    assert(geom(viaHide) == geom(viaSelect),
        "T-R2e [" ~ toolId ~ "]: the tool's currentMask() fallback must act on "
        ~ "exactly the 3 VISIBLE faces.\n  via hide:   " ~ geom(viaHide)
        ~ "\n  via select: " ~ geom(viaSelect));
}

unittest { // poly.extrude, absolute face count + its own all-6 contrast
    // The contrast number is MEASURED here, not predicted: extrude only walls
    // the BOUNDARY edges of the extruded region, so the arithmetic depends on
    // how the operand faces are connected. The visible three ({3,4,5}) form a
    // strip with two shared edges, giving 3 hidden + 3 caps + 8 walls = 14.
    // Asserting a hand-derived 18 here was wrong on the first draft; deriving
    // the contrast by running the same tool over all six is what makes this
    // row honest.
    resetCube();
    cmd("tool.set poly.extrude on");
    cmd("tool.attr poly.extrude distance 0.5");
    // Nothing hidden, nothing selected ⇒ the fallback offers all 6 faces of a
    // CLOSED cube, which the extrude kernel refuses (no boundary edges to wall).
    // Posted without cmd()'s ok-assert precisely because the refusal is the
    // measurement: it is what an unfiltered currentMask() would do here.
    const string all6Status =
        postJson("/api/command", "tool.doApply")["status"].str;
    const size_t all6Faces = model()["faces"].array.length;
    cmd("tool.set poly.extrude off");

    resetCube();
    auto before = verts(model());
    hideFaces(HIDE_FACES);
    cmd("tool.set poly.extrude on");
    cmd("tool.attr poly.extrude distance 0.5");
    cmd("tool.doApply");
    auto m = model();
    cmd("tool.set poly.extrude off");

    assert(m["faces"].array.length == 14,
        "T-R2e: extruding the 3 VISIBLE cube faces must give 14 faces "
        ~ "(3 hidden + 3 caps + 8 boundary walls), got "
        ~ m["faces"].array.length.to!string);
    assert(all6Status != "ok" || all6Faces != 14,
        "T-R2e: the all-6 run must produce a DIFFERENT outcome from the "
        ~ "3-visible run, or this row cannot tell a filtered currentMask() "
        ~ "from an unfiltered one. Observed all-6: status=" ~ all6Status
        ~ " faces=" ~ all6Faces.to!string);
    // The 8 original cube corners must all still be present unmoved — the
    // extrude only appends. Read positionally so an index shift is visible.
    auto after = verts(m);
    foreach (vi; 0 .. 8)
        foreach (c; 0 .. 3)
            assert(after[vi][c] == before[vi][c],
                "T-R2e: original vertex " ~ vi.to!string ~ " moved on axis "
                ~ c.to!string);
}

unittest { shapeERow("poly.extrude",           "distance 0.5"); }
unittest { shapeERow("mesh.polyInsetTool",     "inset 0.2"); }
unittest { shapeERow("poly.bevel",             "inset 0.15"); }
unittest { shapeERow("mesh.smoothShiftTool",   "shift 0.2"); }
