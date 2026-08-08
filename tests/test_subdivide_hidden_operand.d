// Subdivision excludes hidden faces from the OPERAND (task 0632).
//
// THE LAW
// -------
// A hidden face is not "preserved across" a subdivision — it is kept out of
// the operation. Bake a six-quad cube with one face hidden and the result is
// 21 polygons with exactly ONE hidden face: five faces × four children, plus
// the sixth carried through whole. Never 24 (the hidden face refined, its bit
// handed to four children) and never "1 hidden lost" (the rebuild dropped the
// mark). The three readings give three different numbers, which is the only
// reason any assertion here means anything — a test that asserted "hiding did
// not get lost" would pass on two of the three.
//
// WHAT THIS FILE COVERS THAT THE FROZEN FIXTURE DOES NOT
// ------------------------------------------------------
// `tests/test_fixture_subdivide_hidden_face.d` freezes the measured reference
// rows for the DEFAULT subdivision type with the hidden face at index 0. This
// file is the engine-side law, and is deliberately complementary:
//   * the hidden face is a MIDDLE index (f2), not index 0 and not the last —
//     see the note on f5 below;
//   * all three modes of `mesh.subdivide` plus `mesh.subdivide_faceted`, where
//     the fixture drives only the default;
//   * the surviving face is asserted BY IDENTITY (which side of the cube it
//     is), not by index — the fixture records indices and says explicitly that
//     they are output ordering, not semantics;
//   * the Vertices-mode gate, which no fixture row reaches.
// Only the default-mode rows have a reference measurement behind them. The
// flat / smooth / faceted rows assert that vibe3d answers the same law
// consistently across its own modes; they are not claimed parity.
//
// FIXTURE CHOICE — WHY f2 AND NOT f5
// -----------------------------------
// makeCube()'s faces are
//   f0=[0,3,2,1] f1=[4,5,6,7] f2=[0,4,7,3] f3=[1,2,6,5] f4=[3,7,6,2] f5=[0,1,5,4]
// With the hidden face at f5 (the LAST index), an operand mask that was one
// element short would leave it out for entirely the wrong reason — every
// consumer reads an out-of-range mask slot as "unmarked" — and the row could
// not tell a clamped-off-the-end implementation from an excluding one. f2 is
// in the middle, and it is the x = -0.5 side of the cube, which is what the
// identity assertion keys off.
//
// IDENTITY, NOT COUNTING
// ----------------------
// A count alone cannot tell "excluded the right face" from "excluded some
// face". The survivor is checked by geometry: it is the widened cage face
// (eight corners — its four originals plus the four edge points its refined
// neighbours spliced in), and every one of those corners shares one X, on the
// negative side. Any other cube side spans x from -0.5 to +0.5, so it can
// never satisfy that; a refined child of the hidden face would have four
// corners, not eight. The shared X is compared as "all equal and negative"
// rather than "= -0.5" because the smooth mode relaxes it to -5/12.

import std.net.curl;
import std.json;
import std.conv    : to;
import std.math    : fabs;
import std.format  : format;

void main() {}

immutable baseUrl = "http://localhost:8080";

JSONValue getJson(string p) { return parseJSON(cast(string) get(baseUrl ~ p)); }

JSONValue postJson(string p, string b) {
    return parseJSON(cast(string) post(baseUrl ~ p, b));
}

void postOk(string p, string b) {
    auto j = postJson(p, b);
    assert(j["status"].str == "ok", p ~ " failed: " ~ j.toString);
}

void cmd(string s) {
    auto j = postJson("/api/command", s);
    assert(j["status"].str == "ok", "cmd `" ~ s ~ "` failed: " ~ j.toString);
}

/// The hidden cage face: a MIDDLE index, and the x = -0.5 side. See the header.
enum int HIDDEN_FACE = 2;

struct Bake {
    size_t polys;
    int[]  hidden;
    JSONValue model;
}

Bake bake() {
    Bake b;
    b.model = getJson("/api/model");
    b.polys = b.model["faces"].array.length;
    foreach (i, v; b.model["faceHidden"].array)
        if (v.type == JSONType.true_) b.hidden ~= cast(int) i;
    return b;
}

string sIdx(const int[] v) {
    string s = "[";
    foreach (i, x; v) { if (i) s ~= ","; s ~= x.to!string; }
    return s ~ "]";
}

void selectPolys(const int[] idx) {
    string b = `{"mode":"polygons","indices":[`;
    foreach (i, x; idx) { if (i) b ~= ","; b ~= x.to!string; }
    postOk("/api/select", b ~ "]}");
}

size_t selectedFaceCount() {
    return getJson("/api/selection")["selectedFaces"].array.length;
}

/// Fresh cube, face `HIDDEN_FACE` hidden, mark confirmed present. Every row
/// re-runs this from scratch so no row can inherit another's state.
void cubeWithOneHiddenFace() {
    postOk("/api/reset", "");
    cmd(`{"id":"history.clear"}`);
    selectPolys([HIDDEN_FACE]);
    cmd(`{"id":"mesh.hide"}`);
    auto b = bake();
    assert(b.polys == 6, format("control: cage must be 6 quads, got %d", b.polys));
    assert(b.hidden == [HIDDEN_FACE],
        format("control: the mark must be on f%d before any bake — hidden %s",
               HIDDEN_FACE, sIdx(b.hidden)));
}

/// The whole law for one bake, in one place: 21 polygons, exactly one hidden
/// face, and that face is the one we hid.
void assertExcludedNotRefined(ref Bake b, string what) {
    assert(b.polys == 21,
        format("%s: %d polygons, want 21 — five faces × four children plus the "
               ~ "untouched hidden one. 24 would mean the hidden face was refined "
               ~ "like any other.", what, b.polys));
    assert(b.hidden.length == 1,
        format("%s: %d hidden faces, want exactly 1. 0 means the rebuild dropped "
               ~ "the mark; 4 means the hidden face was refined and every child "
               ~ "inherited it. Hidden: %s", what, b.hidden.length, sIdx(b.hidden)));

    immutable int hi = b.hidden[0];
    auto face = b.model["faces"].array[hi];
    assert(face.array.length == 8,
        format("%s: the surviving hidden face has %d corners, want 8 — the cage "
               ~ "face carried through whole and widened at the four edges its "
               ~ "refined neighbours bisected. Four corners would mean a refined "
               ~ "CHILD kept the mark instead.", what, face.array.length));

    // Every corner on one X, and that X negative: the -X side, which is f2.
    double x0 = b.model["vertices"].array[face.array[0].integer].array[0].get!double;
    assert(x0 < 0.0,
        format("%s: the surviving face sits at x = %.4f — the face that was "
               ~ "hidden is the NEGATIVE-x side", what, x0));
    foreach (c; face.array) {
        auto p = b.model["vertices"].array[c.integer].array;
        immutable double x = p[0].get!double;
        assert(fabs(x - x0) < 1e-5,
            format("%s: the surviving face must lie in ONE x-plane (x = %.4f), got "
                   ~ "a corner at x = %.4f — a different side of the cube survived",
                   what, x0, x));
    }
}

unittest {
    // ---- VACUITY GUARD ------------------------------------------------------
    // With nothing hidden, the very same bake is the wholesale 24-quad refine.
    // Without this, "21" below could be the number this command always
    // produces and every row under it would be measuring nothing.
    {
        postOk("/api/reset", "");
        cmd(`{"id":"history.clear"}`);
        selectPolys([]);
        assert(selectedFaceCount() == 0, "vacuity guard: nothing selected");
        cmd(`{"id":"mesh.subdivide"}`);
        auto b = bake();
        assert(b.polys == 24,
            format("vacuity: with nothing hidden the bake must still refine every "
                   ~ "face — 24 polygons, got %d. If this reads 21 the fix turned "
                   ~ "the ordinary bake into a selective one.", b.polys));
        assert(b.hidden.length == 0,
            format("vacuity: nothing was hidden, so nothing may come back hidden — "
                   ~ "got %s", sIdx(b.hidden)));
    }

    // ---- THE DEFAULT MODE, NOTHING SELECTED ---------------------------------
    // The row the reference measured. Before task 0632 this read 24 polygons
    // with four hidden faces.
    {
        cubeWithOneHiddenFace();
        selectPolys([]);
        assert(selectedFaceCount() == 0, "nothing selected at the bake");
        cmd(`{"id":"mesh.subdivide"}`);
        auto b = bake();
        assertExcludedNotRefined(b, "default mode, nothing selected");
    }

    // ---- THE OTHER THREE BAKE PATHS -----------------------------------------
    // Same law, three more kernels. `mode` is a real attribute of
    // mesh.subdivide (an unknown VALUE is rejected — see the mode:bogus row
    // below — so these three cannot be silently ignoring the argument).
    foreach (spec; [
        [`{"id":"mesh.subdivide","mode":"flat"}`,   "flat mode"],
        [`{"id":"mesh.subdivide","mode":"smooth"}`, "smooth mode"],
        [`{"id":"mesh.subdivide_faceted"}`,         "mesh.subdivide_faceted"],
    ]) {
        cubeWithOneHiddenFace();
        selectPolys([]);
        cmd(spec[0]);
        auto b = bake();
        assertExcludedNotRefined(b, spec[1] ~ ", nothing selected");
    }

    // An unknown mode VALUE must be refused, not silently defaulted — this is
    // what licenses reading the three rows above as three different kernels.
    {
        cubeWithOneHiddenFace();
        selectPolys([]);
        auto j = postJson("/api/command", `{"id":"mesh.subdivide","mode":"bogus"}`);
        assert(j["status"].str != "ok",
            "an unknown `mode` value must be refused: " ~ j.toString);
        assert(bake().polys == 6, "a refused bake must leave the cage alone");
    }

    // ---- EVERYTHING SELECTED ------------------------------------------------
    // Selecting all six polygons yields FIVE: a hidden face cannot be selected.
    // The selection branch then reaches the same 21 by a different route, so
    // this row is a check that the two branches agree, not a repeat.
    {
        cubeWithOneHiddenFace();
        selectPolys([0, 1, 2, 3, 4, 5]);
        assert(selectedFaceCount() == 5,
            format("selecting every polygon must yield 5, not %d — the hidden face "
                   ~ "cannot be selected at all", selectedFaceCount()));
        cmd(`{"id":"mesh.subdivide"}`);
        auto b = bake();
        assertExcludedNotRefined(b, "default mode, everything selected");
    }

    // ---- THE NON-POLYGON MODE GATE ------------------------------------------
    // The whole-mesh fallback fires in Vertices mode too (the command ignores
    // any face selection there by design). It must narrow to the VISIBLE mesh
    // in that branch as well — nothing about the gate makes hidden faces
    // operable again.
    {
        cubeWithOneHiddenFace();
        postOk("/api/select", `{"mode":"vertices","indices":[]}`);
        assert(getJson("/api/selection")["mode"].str == "vertices",
            "this row must run with Vertices as the edit mode");
        cmd(`{"id":"mesh.subdivide"}`);
        auto b = bake();
        assertExcludedNotRefined(b, "Vertices mode, nothing selected");
    }

    // ---- UNDO ---------------------------------------------------------------
    // One entry takes the whole bake, geometry and mark together.
    {
        cubeWithOneHiddenFace();
        selectPolys([]);
        cmd(`{"id":"mesh.subdivide"}`);
        assert(bake().polys == 21, "undo row: the bake must have happened first");
        postOk("/api/undo", "");
        auto b = bake();
        assert(b.polys == 6,
            format("undo: %d polygons, want 6 — one entry must take the whole bake",
                   b.polys));
        assert(b.hidden == [HIDDEN_FACE],
            format("undo: hidden %s, want [%d] — an undo that restored the geometry "
                   ~ "without the mark would read [] here",
                   sIdx(b.hidden), HIDDEN_FACE));
    }
}
