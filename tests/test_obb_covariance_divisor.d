// The moment divisor inside the oriented box — the numerics half of what task
// 0648 measured and task 0649 deliberately left open.  (Task 0658.)
//
// ── WHAT THIS PINS ─────────────────────────────────────────────────────────
//
// `toolpipe.obbox.obbFromPoints` accumulates six second moments `S` and three
// first moments `M` about the axis-aligned bbox centre and forms
//
//     C = s*S - (s*M)(s*M)^T
//
// The claim asserted here is the value of `s`: it is `1 / (2n)`, and the SAME
// `s` scales both accumulations.  With `mu = mean - aabbCentre` that gives
//
//     C = (1/2) * [ Cov + (1/2) mu*mu^T ]
//
// — the ordinary covariance about the mean plus half of `mu mu^T`.  The
// evidence is the reference's own published axis frames on the five item
// transforms of 0648, frozen in `tests/fixtures/acen_item_space.json`: with
// this `s` our box rows reproduce all five to ~1e-6, and with the textbook
// `s = 1/n` they miss by up to 3.4e-3.
//
// ── WHY THE OBVIOUS TEST WOULD ASSERT NOTHING ──────────────────────────────
//
// "The axes match" passes under BOTH divisors on almost every subject, and
// the reason is worth stating because it is what kept this hidden through the
// whole port.  Changing a divisor alone multiplies `C` by a positive scalar,
// and the eigenvectors of a matrix are invariant under that.  Here the scalar
// reading is only HALF the story — `s` multiplies `M` before it is squared, so
// the subtracted rank-1 term picks up `s^2` against the second moments' `s` —
// but the leftover is proportional to `mu mu^T`, and `mu` is ZERO on every
// centrally symmetric subject.  Squares, cubes, regular n-gons, lattices,
// rods: on all of them the two divisors agree bit for bit.  Every rig this
// port was built and recorded on is one of those.
//
// So the subject has to be OFF CENTRE, and 0648's is: its selected quad is
// irregular by construction, mean (1.925, 1.1, -1.3) against bbox mid
// (1.95, 1.1, -1.3).
//
// ── THE CONTROLS AND THE FIX, AND WHY THE SPLIT IS DERIVED ─────────────────
//
// The subject is PLANAR, so a correct covariance has the plane's normal as an
// exact null eigenvector and must return it as row 2 — exactly, on every
// stand, no matter how the item is transformed.  The reference does NOT
// return it on all of them, and the mechanism says precisely when:
//
//   * the plane is AXIS-ALIGNED  => its axis-aligned bbox centre lies IN the
//     plane => `mu` is in-plane => the added rank-1 term cannot tilt the
//     normal => row 2 is the exact plane normal.  These stands are CONTROLS:
//     they must reproduce the recorded normal AND agree with the geometric
//     one, and they would do so under either divisor.
//   * the plane is TILTED => the bbox centre leaves the plane => `mu` gains an
//     out-of-plane component => row 2 tilts off the geometric normal by a
//     measurable amount.  These stands are the FIX: reproducing the recorded
//     normal there REQUIRES being wrong about the plane in exactly the
//     reference's way, which no correct covariance can be.
//
// Which stand is which is DERIVED here from the world points (is the bbox
// centre in the plane?), never listed — a hard-coded list would silently stop
// describing the fixture if the fixture ever moved.
//
// ── WHAT THIS DELIBERATELY DOES NOT ASSERT ─────────────────────────────────
//
// Which box row lands in the packet's `right` slot.  The reference's election
// tail is unread (`toolpipe.obbox.axisFrameFromBox` says so in its own
// header) and it disagrees with ours on three of these five stands.  So the
// in-plane pair is matched as a PAIR, up to sign and up to which slot it came
// from; row 2, whose sign IS pinned by the sign-fix step, is matched signed.
// That is the same reading `tests/test_acen_item_space.d` takes, and it is
// orthogonal to the divisor: a row-slot swap cannot turn a 3.4e-3 residual
// into a 1e-6 one.
//
// This is a PURE test.  It calls the kernel on the same world points the
// stage enumerates, rather than driving the app, because the claim is about
// arithmetic and the SPACE those points live in is already asserted end to
// end by `tests/test_acen_item_space.d` (task 0649).

import std.json;
import std.math   : fabs, sqrt, abs;
import std.format : format;
import std.algorithm : max, min;

import math     : Vec3, ModelSpace, normalize, dot;
import mesh     : Mesh;
import document : ItemXform;
import toolpipe.obbox : ObbFrame, ObbSource, obbFromPoints;

void main() {}

// The fixture is embedded at COMPILE time (`-J=tests`), so this test does not
// depend on the working directory a runner happens to start it from.
enum string FIXTURE_JSON = import("fixtures/acen_item_space.json");

// --------------------------------------------------------------------------
// Tolerances.
//
// REPRO is what the reference's rows must be reproduced to, and it is sized
// from BOTH sides rather than picked:
//
//   * measured residual with this divisor, worst of the five stands: 6.6e-7,
//     which is itself near the floor set by the recording's six printed
//     decimals and by our float32 row storage;
//   * residual with the plain `1/n` divisor, SMALLEST of the five stands:
//     8.3e-5 (the two axis-aligned untranslated ones; the rotated stands miss
//     by 3.4e-3, forty times further).
//
// 1e-5 sits fifteen-fold above the first and eight-fold below the second, so
// it separates the two readings on ALL FIVE stands. A looser 1e-4 — the
// obvious round number — would still catch the rotated stands but would let
// the identity and translate ones pass under the wrong divisor, i.e. it would
// quietly turn three of the five into decoration.
//
// TILT is the floor for "row 2 is measurably off the geometric plane normal".
// Measured 2.6e-3 and 1.6e-3 on the two tilted stands, so 1e-3 is a floor with
// margin, not a threshold tuned to a number.
enum double REPRO = 1e-5;
enum double TILT  = 1e-3;
enum double IN_PLANE = 1e-5;   // "the bbox centre lies in the plane" — float32 grade
// --------------------------------------------------------------------------

JSONValue fixture() {
    static JSONValue cached;
    static bool loaded = false;
    if (!loaded) { cached = parseJSON(FIXTURE_JSON); loaded = true; }
    return cached;
}

double num(JSONValue e) {
    return (e.type == JSONType.integer)  ? cast(double) e.integer
         : (e.type == JSONType.uinteger) ? cast(double) e.uinteger
                                         : e.floating;
}
Vec3 vec3Of(JSONValue j) {
    return Vec3(cast(float) num(j.array[0]), cast(float) num(j.array[1]),
                cast(float) num(j.array[2]));
}
string sv(Vec3 v) { return format("(%.6f, %.6f, %.6f)", v.x, v.y, v.z); }

/// Distance between two unit directions, IGNORING sign. An eigenvector's sign
/// is its solver's business; the one sign this port does pin (row 2's, set by
/// the reference-direction test) is compared with `signedDist` instead.
double dirDist(Vec3 a, Vec3 b) {
    double p = max(max(fabs(a.x - b.x), fabs(a.y - b.y)), fabs(a.z - b.z));
    double m = max(max(fabs(a.x + b.x), fabs(a.y + b.y)), fabs(a.z + b.z));
    return min(p, m);
}
double signedDist(Vec3 a, Vec3 b) {
    return max(max(fabs(a.x - b.x), fabs(a.y - b.y)), fabs(a.z - b.z));
}

/// The recorded in-plane pair `{right, up}` against our `{m[0], m[1]}`, up to
/// sign and up to which slot each landed in. Returns the better of the two
/// pairings — see the header for why the slot itself is not asserted.
double inPlanePairDist(Vec3 m0, Vec3 m1, Vec3 recRight, Vec3 recUp) {
    double direct  = max(dirDist(m0, recRight), dirDist(m1, recUp));
    double swapped = max(dirDist(m0, recUp),    dirDist(m1, recRight));
    return min(direct, swapped);
}

// --------------------------------------------------------------------------
// The stand, rebuilt through the project's OWN primitives.
//
// The item matrix is recomposed from the fixture's pos/rot/scl by `ItemXform`
// rather than read out of its stored `matrix` field, and then CHECKED against
// that field. Task 0649 was bitten by the opposite habit: a frozen constant
// that had quietly stopped describing the stand it named. Recomputing and
// self-checking catches that in the test instead of in a reader's head.
// --------------------------------------------------------------------------
struct Stand {
    string     name;
    Vec3[]     worldPts;    /// the selected face's vertices, in enumeration order
    Vec3       worldNormal; /// the sign-fix reference direction, as the stage builds it
    Vec3       recRight, recUp, recFwd;
}

Stand buildStand(string xformName) {
    auto fx = fixture();
    auto xfj = fx["itemTransforms"][xformName];

    ItemXform xf;
    xf.pos = vec3Of(xfj["pos"]);
    xf.rot = vec3Of(xfj["rot"]);
    xf.scl = vec3Of(xfj["scl"]);

    // Self-check: the recomposed matrix must be the one the capture recorded.
    float[16] composed = xf.composedMatrix();
    foreach (i; 0 .. 16) {
        double want = num(xfj["matrix"].array[i]);
        assert(fabs(composed[i] - want) < 2e-6,
               format("%s: recomposing the item matrix from the fixture's own "
                      ~ "pos/rot/scl gives m[%d] = %.8f where the fixture "
                      ~ "records %.8f. The euler triple and this codebase's "
                      ~ "composition order have drifted apart, and every "
                      ~ "number below would be measured on a different stand "
                      ~ "than the one the reference was recorded on.",
                      xformName, i, composed[i], want));
    }
    ModelSpace ms = xf.modelSpace();
    assert(ms.invertible, xformName ~ ": the stand's item matrix must be invertible");

    Mesh m;
    foreach (v; fx["stand"]["vertices"].array) m.vertices ~= vec3Of(v);
    foreach (f; fx["stand"]["faces"].array) {
        uint[] idx;
        foreach (vi; f.array) idx ~= cast(uint) vi.integer;
        m.addFace(idx);
    }
    uint sel = cast(uint) fx["stand"]["selectedFace"].integer;

    Stand s;
    s.name = xformName;
    // EXACTLY the enumeration `AxisStage.computeSelectionBboxBasis` performs in
    // Polygons mode with one face selected: the face's own corner order,
    // positions through `toWorldPoint`, the normal through `toWorldNormal`.
    foreach (vi; m.faces[sel])
        s.worldPts ~= ms.isIdentity ? m.vertices[vi] : ms.toWorldPoint(m.vertices[vi]);
    Vec3 nLocal = m.faceNormal(sel);
    s.worldNormal = ms.isIdentity ? nLocal : ms.toWorldNormal(nLocal);

    bool found = false;
    foreach (c; fx["cells"].array) {
        if (c["itemTransform"].str != xformName || c["mode"].str != "select") continue;
        s.recRight = vec3Of(c["right"]);
        s.recUp    = vec3Of(c["up"]);
        s.recFwd   = vec3Of(c["fwd"]);
        found = true;
        break;
    }
    assert(found, "no recorded `select` cell for item transform " ~ xformName);
    return s;
}

string[] standNames() {
    string[] names;
    foreach (string k, JSONValue _; fixture()["itemTransforms"].object) names ~= k;
    return names;
}

// --------------------------------------------------------------------------

unittest { // the five stands reproduce the reference's box rows
    auto names = standNames();
    assert(names.length == 5,
           format("the fixture must carry all five item transforms; found %d. "
                  ~ "The divisor was derived from five stands and fitting it "
                  ~ "to fewer is exactly what task 0658 forbids.",
                  names.length));

    int tilted = 0, aligned = 0;
    foreach (name; names) {
        auto s = buildStand(name);
        auto box = obbFromPoints(s.worldPts, s.worldNormal);
        assert(box.ok && box.source == ObbSource.Covariance,
               s.name ~ ": a four-point selection must take the covariance path");

        double eFwd = signedDist(normalize(box.m[2]), s.recFwd);
        double eIn  = inPlanePairDist(normalize(box.m[0]), normalize(box.m[1]),
                                      s.recRight, s.recUp);

        assert(eFwd < REPRO,
               format("%s: box row 2 must reproduce the reference's published "
                      ~ "`fwd` %s; got %s (off by %.3e, tolerance %.0e). With "
                      ~ "the divisor reverted to the textbook 1/n this row is "
                      ~ "off by 2.6e-3 on the rotated stand and 1.6e-3 on the "
                      ~ "combined one — see the module header of "
                      ~ "source/toolpipe/obbox.d.",
                      s.name, sv(s.recFwd), sv(normalize(box.m[2])), eFwd, REPRO));
        assert(eIn < REPRO,
               format("%s: the in-plane row pair must reproduce the "
                      ~ "reference's published {right, up} = %s %s; got "
                      ~ "%s %s (best pairing off by %.3e, tolerance %.0e). "
                      ~ "The pair is matched up to sign AND up to slot, so "
                      ~ "this cannot be the unread row-election tail: it is "
                      ~ "the covariance itself. The 1/n divisor answers 3.4e-3 "
                      ~ "here on the rotated stand and 8.4e-5 at identity.",
                      s.name, sv(s.recRight), sv(s.recUp),
                      sv(normalize(box.m[0])), sv(normalize(box.m[1])),
                      eIn, REPRO));

        // ---- the CONTROL / FIX split, derived from the geometry -----------
        Vec3 n = normalize(s.worldNormal);              // the exact plane normal
        Vec3 mn = s.worldPts[0], mx = s.worldPts[0];
        foreach (p; s.worldPts[1 .. $]) {
            if (p.x < mn.x) mn.x = p.x;  if (p.x > mx.x) mx.x = p.x;
            if (p.y < mn.y) mn.y = p.y;  if (p.y > mx.y) mx.y = p.y;
            if (p.z < mn.z) mn.z = p.z;  if (p.z > mx.z) mx.z = p.z;
        }
        Vec3 aabbC = (mn + mx) * 0.5f;
        double h = fabs(dot(n, aabbC - s.worldPts[0]));  // bbox centre off the plane
        double offNormal = dirDist(normalize(box.m[2]), n);

        if (h <= IN_PLANE) {
            ++aligned;
            assert(offNormal < REPRO,
                   format("%s is an AXIS-ALIGNED stand (its bbox centre is "
                          ~ "%.2e off the plane, i.e. in it), so `mu` has no "
                          ~ "out-of-plane part and row 2 MUST be the exact "
                          ~ "plane normal %s; got %s, off by %.3e. This is a "
                          ~ "control: it holds under either divisor, and if it "
                          ~ "fires the breakage is not the divisor.",
                          s.name, h, sv(n), sv(normalize(box.m[2])), offNormal));
        } else {
            ++tilted;
            assert(offNormal > TILT,
                   format("%s is a TILTED stand (its bbox centre sits %.4f off "
                          ~ "the plane), so `mu` has an out-of-plane component "
                          ~ "and row 2 must MISS the geometric plane normal %s "
                          ~ "by more than %.0e; it missed by only %.3e. A "
                          ~ "correct covariance of a planar point set returns "
                          ~ "the plane normal EXACTLY — so passing this "
                          ~ "assertion is only possible for a formula that is "
                          ~ "wrong about the plane in the reference's specific "
                          ~ "way, which is what makes the reproduction above "
                          ~ "evidence rather than coincidence.",
                          s.name, h, sv(n), TILT, offNormal));
        }
    }
    assert(aligned == 3 && tilted == 2,
           format("the fixture must supply BOTH kinds of stand — the "
                  ~ "axis-aligned controls and the tilted ones that carry the "
                  ~ "claim; got %d aligned and %d tilted. With no tilted stand "
                  ~ "this test degenerates into one a correct covariance also "
                  ~ "passes.", aligned, tilted));
}

unittest { // the subject is OFF CENTRE — without this the whole test is vacuous
    // `mu = mean - aabbCentre` is the entire mechanism: at `mu == 0` the two
    // divisors differ by a positive scalar and every assertion above passes
    // under both. So the fixture's own claim to discriminate is checked here
    // rather than trusted, on every stand.
    foreach (name; standNames()) {
        auto s = buildStand(name);
        Vec3 mn = s.worldPts[0], mx = s.worldPts[0], sum = Vec3(0, 0, 0);
        foreach (p; s.worldPts) {
            if (p.x < mn.x) mn.x = p.x;  if (p.x > mx.x) mx.x = p.x;
            if (p.y < mn.y) mn.y = p.y;  if (p.y > mx.y) mx.y = p.y;
            if (p.z < mn.z) mn.z = p.z;  if (p.z > mx.z) mx.z = p.z;
            sum = sum + p;
        }
        Vec3 mu = sum * (1.0f / s.worldPts.length) - (mn + mx) * 0.5f;
        double len = sqrt(cast(double)dot(mu, mu));
        assert(len > 1e-3,
               format("%s: the selected quad must be irregular enough that its "
                      ~ "mean and its bbox centre are different points — "
                      ~ "|mu| = %.6f. At mu = 0 the two divisors are a "
                      ~ "positive scalar apart, eigenvectors are invariant "
                      ~ "under a scalar, and every assertion in this file "
                      ~ "would pass with the divisor reverted.",
                      s.name, len));
    }
}
