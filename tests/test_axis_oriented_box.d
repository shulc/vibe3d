// The AXIS stage's selection frame is the ORIENTED bounding box of the
// selection — the stage-level half of the port whose law lives in
// `source/toolpipe/obbox.d`.
//
// ── WHAT MOVED, AND WHY IT COULD HIDE FOR SO LONG ─────────────────────────
//
// The stage used to build a world-axis-ALIGNED box: per-world-axis min/max
// over the touched vertices, the averaged face normal SNAPPED to the nearest
// world axis, and a fixed per-axis lookup for the second row. An axis-aligned
// box and an oriented box agree EXACTLY when the subject is already
// world-aligned — which is every rig ever recorded against the reference, cube
// faces and a flat ground grid — so no fixture and no reference-comparison leg
// could see the difference. On a rotated subject they diverge completely: a
// cube rotated 30 degrees about X has a face normal 30 degrees off world Y and
// the old code still answered a signed world permutation.
//
// So the cases below split into two kinds, and the split is the point:
//
//   * the AXIS-ALIGNED rows are CONTROLS. They are the recorded ground truth
//     and they must not move by one digit. If they move, the port has changed
//     something it had no licence to change.
//   * the ROTATED rows are the fix. Every one of them fails on the old code
//     with the answer named in its message.
//
// ── WHAT IS NOT ASSERTED, AND WHY ─────────────────────────────────────────
//
// The in-plane orientation of a SQUARE. On a subject whose two in-plane second
// moments are equal the reference's answer is a one-bit cliff, not a
// tie-break: bit-exactly zero cross moment gives world axes, any nonzero
// epsilon gives EXACTLY 45 degrees, and which side a subject lands on is
// decided by float32 vertex storage and the rounding of a box centre rather
// than by the shape. Pinning it would pin somebody's summation order. We use a
// relative degeneracy test and a declared convention of our own instead, and
// the `square` case below asserts THAT — with the refusal in its message —
// rather than a reference answer.

import http_client : testBaseUrl;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.math : fabs, sqrt;
import std.conv : to;
import std.format : format;

import drag_helpers;

void main() {}

alias BASE = testBaseUrl;

enum string SEL_TOP_FACE = `{"mode":"polygons","indices":[4]}`;

// A unit cube rotated 30 degrees about X. Face 4 is the (rotated) +Y face; its
// geometric normal is exactly (0, -cos30, -sin30) = (0, -0.866025, -0.5) with
// this winding.
enum string ROT_CUBE = `{"vertices":[`
    ~ `[-0.5,-0.183013,-0.683013],[0.5,-0.183013,-0.683013],`
    ~ `[0.5,0.683013,-0.183013],[-0.5,0.683013,-0.183013],`
    ~ `[-0.5,-0.683013,0.183013],[0.5,-0.683013,0.183013],`
    ~ `[0.5,0.183013,0.683013],[-0.5,0.183013,0.683013]],`
    ~ `"faces":[[0,1,2,3],[5,4,7,6],[4,0,3,7],[1,5,6,2],[3,2,6,7],[4,5,1,0]]}`;

// The same cube stretched x2 along Z BEFORE the 30-degree rotation, so face 4
// is a genuine 1 x 2.28737 RECTANGLE and its two in-plane second moments are
// well separated. That takes the whole subject off the degeneracy cliff: the
// in-plane pair below comes out of the covariance, not out of our convention.
enum string ROT_RECT = `{"vertices":[`
    ~ `[-0.5,-0.183013,-1.366025],[0.5,-0.183013,-1.366025],`
    ~ `[0.5,0.683013,-0.866025],[-0.5,0.683013,-0.866025],`
    ~ `[-0.5,-0.683013,0.866025],[0.5,-0.683013,0.866025],`
    ~ `[0.5,0.183013,1.366025],[-0.5,0.183013,1.366025]],`
    ~ `"faces":[[0,1,2,3],[5,4,7,6],[4,0,3,7],[1,5,6,2],[3,2,6,7],[4,5,1,0]]}`;

struct Frame { Vec3 right, up, fwd; }

void ok(char[] resp, string what) {
    assert(parseJSON(cast(string)resp)["status"].str == "ok",
           what ~ " failed: " ~ cast(string)resp);
}

string show(Vec3 v) { return format("(%.5f, %.5f, %.5f)", v.x, v.y, v.z); }

Frame frameFor(string sel, string mesh = null, string actr = "select") {
    ok(post(BASE ~ "/api/reset", ""), "reset");
    if (mesh !is null) ok(post(BASE ~ "/api/load-mesh", mesh), "load-mesh");
    ok(post(BASE ~ "/api/command", commandBody("mesh.select", sel)), "select");
    ok(post(BASE ~ "/api/script", "actr." ~ actr), "actr." ~ actr);
    auto ev = parseJSON(cast(string)get(BASE ~ "/api/toolpipe/eval"));
    Vec3 rd(string slot) {
        auto v = ev["axis"][slot].array;
        return Vec3(cast(float)v[0].floating, cast(float)v[1].floating,
                    cast(float)v[2].floating);
    }
    return Frame(rd("right"), rd("up"), rd("fwd"));
}

void near(Vec3 got, Vec3 want, string slot, string why, float eps = 1e-4f) {
    assert(fabs(got.x - want.x) < eps && fabs(got.y - want.y) < eps
           && fabs(got.z - want.z) < eps,
           slot ~ " must be " ~ show(want) ~ " but is " ~ show(got) ~ ". " ~ why);
}

// Every published frame must be orthonormal and right-handed (right x up ==
// fwd). The packet's `mInv` is stored as the TRANSPOSE of `m`, which is the
// inverse only for an orthonormal frame — so this is not decoration, it is the
// precondition every consumer of the packet already assumes.
void assertOrthonormalRH(Frame f, string what) {
    float d(Vec3 a, Vec3 b) { return a.x*b.x + a.y*b.y + a.z*b.z; }
    Vec3 x(Vec3 a, Vec3 b) {
        return Vec3(a.y*b.z - a.z*b.y, a.z*b.x - a.x*b.z, a.x*b.y - a.y*b.x);
    }
    foreach (i, v; [f.right, f.up, f.fwd])
        assert(fabs(sqrt(d(v, v)) - 1.0f) < 1e-4f,
               what ~ ": slot " ~ i.to!string ~ " is not unit length: "
               ~ show(v));
    assert(fabs(d(f.right, f.up)) < 1e-4f && fabs(d(f.right, f.fwd)) < 1e-4f
           && fabs(d(f.up, f.fwd)) < 1e-4f,
           what ~ ": the frame is not orthogonal: " ~ show(f.right) ~ " "
           ~ show(f.up) ~ " " ~ show(f.fwd));
    Vec3 c = x(f.right, f.up);
    assert(fabs(c.x - f.fwd.x) < 1e-4f && fabs(c.y - f.fwd.y) < 1e-4f
           && fabs(c.z - f.fwd.z) < 1e-4f,
           what ~ ": right x up must be fwd, but right x up = " ~ show(c)
           ~ " and fwd = " ~ show(f.fwd));
}

// ── 1. THE CONTROL — the one recorded rig, which must not move ────────────

unittest {
    auto f = frameFor(SEL_TOP_FACE);
    near(f.right, Vec3( 1, 0, 0), "select/right on the recorded cube rig",
         "This row IS the reference recording: a unit cube with its +Y face "
         ~ "selected publishes (+X, -Z, +Y), and the box behind it was "
         ~ "recorded as the rows (0,0,1) / (1,0,0) / (0,1,0). The oriented-box "
         ~ "port must reproduce it exactly — if this moved, the port changed "
         ~ "the ONE case where a reference answer exists.");
    near(f.up,    Vec3( 0, 0, -1), "select/up on the recorded cube rig", "ditto");
    near(f.fwd,   Vec3( 0, 1, 0), "select/fwd on the recorded cube rig", "ditto");
    assertOrthonormalRH(f, "recorded cube rig");
}

unittest { // all six signed face normals of the world-aligned convention
    // These were this stage's shipped answers before the port and the port
    // must not have touched one of them: an axis-aligned box and an oriented
    // box agree exactly on an axis-aligned subject, and that agreement is the
    // whole reason this divergence stayed invisible. A failure here is the
    // port leaking into world-aligned subjects.
    static struct Row { int face; Vec3 r, u, w; string name; }
    immutable Row[6] rows = [
        Row(4, Vec3( 1, 0, 0), Vec3( 0, 0,-1), Vec3( 0, 1, 0), "+Y"),
        Row(5, Vec3(-1, 0, 0), Vec3( 0, 0,-1), Vec3( 0,-1, 0), "-Y"),
        Row(3, Vec3( 0, 0, 1), Vec3( 0,-1, 0), Vec3( 1, 0, 0), "+X"),
        Row(2, Vec3( 0, 0,-1), Vec3( 0,-1, 0), Vec3(-1, 0, 0), "-X"),
        Row(1, Vec3( 1, 0, 0), Vec3( 0, 1, 0), Vec3( 0, 0, 1), "+Z"),
        Row(0, Vec3(-1, 0, 0), Vec3( 0, 1, 0), Vec3( 0, 0,-1), "-Z"),
    ];
    foreach (row; rows) {
        auto f = frameFor(format(`{"mode":"polygons","indices":[%d]}`, row.face));
        string why = "the cube's " ~ row.name ~ " face. An oriented box and a "
            ~ "world-aligned one agree exactly on an axis-aligned subject, so "
            ~ "this row is a CONTROL, not a new claim.";
        near(f.right, row.r, "select/right, " ~ row.name, why);
        near(f.up,    row.u, "select/up, "    ~ row.name, why);
        near(f.fwd,   row.w, "select/fwd, "   ~ row.name, why);
    }
}

// ── 2. THE FIX — a rotated subject keeps its own frame ────────────────────

unittest { // rotated cube: fwd is the face's REAL normal, not a snapped axis
    auto f = frameFor(SEL_TOP_FACE, ROT_CUBE);
    near(f.fwd, Vec3(0, -0.8660254f, -0.5f), "select/fwd on a 30-degree cube",
         "The selected quad's geometric normal is exactly (0, -cos30, -sin30). "
         ~ "The world-aligned box this stage used to build snapped it to the "
         ~ "nearest world axis and answered (0, -1, 0) — 30 degrees wrong on a "
         ~ "subject a user models every day. That snapped answer is what a "
         ~ "failure here almost certainly is.");
    assertOrthonormalRH(f, "30-degree cube");
    // and the in-plane pair follows it rather than staying world-axis
    near(f.up, Vec3(0, 0.5f, -0.8660254f), "select/up on a 30-degree cube",
         "up = fwd x right with right elected as the in-plane row with the "
         ~ "larger |x|. The old answer was world -Z = (0, 0, -1).");
    near(f.right, Vec3(-1, 0, 0), "select/right on a 30-degree cube",
         "the face's other in-plane axis is world-parallel here (the rotation "
         ~ "is about X), so right stays on X and only its sign is the box's");
}

unittest { // a rotated NON-SQUARE face: the in-plane pair is the covariance's
    // This is the case the degeneracy refusal does NOT apply to. The face is
    // 1 x 2.28737, so the two in-plane second moments are well separated and
    // the eigenvectors are determined by the data rather than by a convention.
    // Everything below is therefore a full reference-law answer, not a
    // house rule.
    auto f = frameFor(SEL_TOP_FACE, ROT_RECT);
    // face 4 = (-0.5,0.683013,-0.866025) (0.5,0.683013,-0.866025)
    //          (0.5,0.183013,1.366025)   (-0.5,0.183013,1.366025)
    // long in-plane edge = (0,-0.5,2.23205), |.| = 2.28737
    //   -> unit (0, -0.21859, 0.97582); normal = (0, -0.97582, -0.21859)
    near(f.fwd, Vec3(0, -0.975818f, -0.218590f),
         "select/fwd on a rotated 1x2 face",
         "the quad's exact geometric normal. Stretching Z by two BEFORE the "
         ~ "rotation tilts the normal off 30 degrees, so a failure that lands "
         ~ "on (0,-0.866,-0.5) means the mesh is wrong, and one that lands on "
         ~ "(0,-1,0) means the frame is still world-snapped.");
    near(f.right, Vec3(-1, 0, 0), "select/right on a rotated 1x2 face",
         "the SHORT in-plane axis wins the election because the election is "
         ~ "argmax |row.x| over the two in-plane rows and the long axis has no "
         ~ "x component at all here");
    near(f.up, Vec3(0, 0.218590f, -0.975818f), "select/up on a rotated 1x2 face",
         "the long in-plane axis, as fwd x right");
    assertOrthonormalRH(f, "rotated 1x2 face");
}

unittest { // local runs the SAME computation and must not drift from select
    // 0557 crossed these two modes and this is the property that keeps them
    // together through a change to the frame's CONTENT.
    auto s = frameFor(SEL_TOP_FACE, ROT_RECT, "select");
    auto l = frameFor(SEL_TOP_FACE, ROT_RECT, "local");
    near(l.right, s.right, "local/right", "local and select run one computation");
    near(l.up,    s.up,    "local/up",    "local and select run one computation");
    near(l.fwd,   s.fwd,   "local/fwd",   "local and select run one computation");
}

// ── 3. THE REFUSAL — the square's in-plane answer is OURS, and says so ────

unittest {
    // An axis-aligned square face. The reference has TWO answers here and
    // which one it gives is decided by float32 storage and the rounding of a
    // box centre, not by the shape: bit-exactly zero cross moment gives the
    // world axes, any nonzero epsilon gives exactly 45 degrees. We take the
    // first branch by a RELATIVE degeneracy test and a declared convention,
    // and we do not chase the second — reproducing it means reproducing
    // somebody's summation order.
    auto f = frameFor(SEL_TOP_FACE);
    assert(fabs(fabs(f.right.x) - 1.0f) < 1e-4f,
           "the in-plane pair on a SQUARE must be the world axes — our declared "
           ~ "degenerate convention, which is also the reference's exact-zero "
           ~ "branch. right = " ~ show(f.right) ~ ". A value near "
           ~ "(0.7071, 0, 0.7071) means the degeneracy stabiliser has stopped "
           ~ "firing and the raw eigensolver's 45-degree answer is leaking "
           ~ "through: that answer is a cancellation artifact of OUR "
           ~ "arithmetic, not a behaviour, and this file refuses to pin it.");
}

// ── 4. THE TWO CONSTRUCTIONS THAT BYPASS THE COVARIANCE ───────────────────
//
// One or two enumerated vertices make the covariance rank-deficient and
// useless, so the frame is rebuilt from mesh topology instead. NOTHING IN ANY
// RECORDING EXERCISES EITHER OF THESE — both capture rigs had 25 and 4 points
// — so they are landed on the static read alone and these two cases pin the
// port, not a reference answer.

unittest { // count == 1 — the vertex's geometric normal
    auto f = frameFor(`{"mode":"vertices","indices":[1]}`);
    // v1 = (0.5,-0.5,-0.5); its three incident faces are +X, -Y, -Z, so the
    // uniform average of their normals is (1,-1,-1)/sqrt(3).
    enum float T = 0.5773503f;
    near(f.fwd, Vec3(T, -T, -T), "select/fwd on a single vertex",
         "a one-vertex selection takes the vertex's geometric normal, not a "
         ~ "covariance of one point and not a snapped world axis. The old code "
         ~ "answered world +X here.");
    assertOrthonormalRH(f, "single vertex");
}

unittest { // count == 2 — the edge
    auto f = frameFor(`{"mode":"vertices","indices":[0,1]}`);
    // v0 = (-0.5,-0.5,-0.5), v1 = (0.5,-0.5,-0.5): the direction is world +X
    // and the two vertices bound a polygon edge whose two faces are -Y and -Z,
    // so the average normal is (0,-1,-1)/sqrt(2).
    near(f.right, Vec3(1, 0, 0), "select/right on a two-vertex selection",
         "the edge DIRECTION, with its dominant component forced positive. A "
         ~ "two-point subject is a line: its covariance has one non-zero "
         ~ "eigenvalue and cannot orient a frame, so the direction and the "
         ~ "edge's average polygon normal build it instead.");
    enum float H = 0.7071068f;
    near(f.fwd, Vec3(0, H, -H), "select/fwd on a two-vertex selection",
         "direction x average-normal. The old code answered world -Y here, "
         ~ "from a snapped sum of the two vertices' incident face normals.");
    assertOrthonormalRH(f, "two-vertex selection");
}
