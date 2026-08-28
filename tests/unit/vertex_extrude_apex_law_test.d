// Frozen-fixture cell for the vertex-extrude apex/ring interaction
// (task 2890, capture campaign batch B), reading
// `tests/fixtures/vertex_extrude_apex_law.json`.
//
// WHY IT EXISTS. The shipped law is `apex displacement = shift + width`,
// derived from exactly ONE measured cell -- and that cell had
// `shift == width`, the single ratio at which `shift`, `shift + width`,
// `2*shift` and `2*width` all predict the same number. Its own author
// flagged it TENTATIVE and asked for a second combo. The re-measurement
// (eight cells, two stands, two boots of the reference's headless command
// lane) says the apex moves by `shift` alone, and says so twice over: the
// reversed pair (0.1, 0.3) and (0.3, 0.1) moves the apex 0.1 and 0.3, and
// doubling the width leaves the apex bit-identical. The old cell was not
// merely unable to separate the candidates -- re-measured, it does not
// reproduce its own recorded value (0.4 recorded, 0.2 measured).
//
// WHY TWO STANDS, and this is the part a cube cannot do. A cube corner
// separates the MAGNITUDE candidates and nothing else: there the mean of
// the incident unit face normals, the area-weighted mean, and the outward
// body diagonal all point the same way, so any DIRECTION law fitted on it
// is evidence about magnitude only. The fixture's second stand is a closed
// fan of four triangles of deliberately unequal area, where those
// candidates sit 0, 2.53 and 77.5 degrees apart.
//
// WHAT IT PINS. The measured law, and the claim that the stands
// discriminate. The law below is re-implemented here from the fixture's
// prose and shares no code with the generator that wrote the numbers, so a
// cell reddens from BOTH sides: change a frozen number and the law check
// fails, change the law and every cell fails. The refutation block is not
// decoration either -- each refuted candidate is EVALUATED on the frozen
// cells and asserted to miss, which is what makes "these cells
// discriminate" a checked statement rather than a claim in a comment.
//
// WHAT IT DOES NOT PIN, deliberately. Our own kernel.
// `mesh_ops/extrude.d`'s `extrudeVerticesByMask` still ships the refuted
// `shift + width` line, and correcting it is a PORT, not a capture: it
// reddens a text census that pins the statement's exact spelling and
// invalidates the frozen `tests/fixtures/undo_parity/extrude_extend.json`
// capture, which records the old geometry. Both were confirmed red before
// the change was reverted. That divergence is now a MEASURED row in the
// behaviour-gap register with this fixture named as its evidence; this
// cell exists so whoever ports it starts from the measured law instead of
// re-deriving it from a stand that cannot fail.
//
// Also not pinned: the per-polygon normal CONVENTION for non-planar
// n-gons -- both stands are made of planar faces, where Newell's method
// and a corner-triangle normal agree exactly -- and the falloff weight,
// which multiplies the shift at the reference's own compute site but is 1
// in every cell here. Read, not exercised.
//
// MUTATION (seen red, in isolation): set the `apex` of the (0.1, 0.3) cell
// to what `shift + width` predicts. `apex law on cube_corner ...` reddens.
// The complementary mutation -- deleting every cell but the original
// `shift == width` one -- makes the refuted law pass the law check, which
// is why the discrimination assertions below refuse a fixture that has
// lost its discriminating cells.
module tests.unit.vertex_extrude_apex_law_test;

import std.json;
import std.file   : readText;
import std.math   : abs, sqrt, acos, PI;
import std.format : format;

private enum string kFixture = "tests/fixtures/vertex_extrude_apex_law.json";

private alias V3 = double[3];

private double num(JSONValue v) {
    switch (v.type) {
        case JSONType.float_:   return v.floating;
        case JSONType.integer:  return cast(double) v.integer;
        case JSONType.uinteger: return cast(double) v.uinteger;
        default: assert(false, "fixture: expected a number, got " ~ v.toString);
    }
}

private V3 vec3(JSONValue v) {
    assert(v.type == JSONType.array && v.array.length == 3,
           "fixture: want a 3-vector, got " ~ v.toString);
    return [num(v.array[0]), num(v.array[1]), num(v.array[2])];
}

private V3 sub(V3 a, V3 b) { return [a[0]-b[0], a[1]-b[1], a[2]-b[2]]; }
private V3 add(V3 a, V3 b) { return [a[0]+b[0], a[1]+b[1], a[2]+b[2]]; }
private V3 scale(V3 a, double k) { return [a[0]*k, a[1]*k, a[2]*k]; }
private double dot(V3 a, V3 b) { return a[0]*b[0] + a[1]*b[1] + a[2]*b[2]; }
private double len(V3 a) { return sqrt(dot(a, a)); }
private V3 cross(V3 a, V3 b) {
    return [a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0]];
}
private V3 unit(V3 a) { const double L = len(a); assert(L > 1e-15); return scale(a, 1.0/L); }
private double dist(V3 a, V3 b) { return len(sub(a, b)); }

// A stand, rebuilt from the fixture's own description.
private struct Stand {
    V3[]     verts;
    uint[][] faces;
    uint     sel;
}

private Stand stand(JSONValue fx, string name) {
    auto s = fx["stands"][name];
    Stand st;
    foreach (v; s["vertices"].array) st.verts ~= vec3(v);
    foreach (f; s["faces"].array) {
        uint[] ring;
        foreach (k; f.array) ring ~= cast(uint) num(k);
        st.faces ~= ring;
    }
    st.sel = cast(uint) num(s["selected"]);
    return st;
}

// The face's own unit normal, by the cross product of its first two edges.
// Every face on both stands is planar, so this is exact here.
private V3 faceNormal(in Stand st, in uint[] ring) {
    return unit(cross(sub(st.verts[ring[1]], st.verts[ring[0]]),
                      sub(st.verts[ring[2]], st.verts[ring[0]])));
}

// ---- the candidate directions, the read one first ------------------------
private V3 dirMeanUnitNormals(in Stand st) {          // the MEASURED law
    V3 acc = [0.0, 0.0, 0.0];
    foreach (ring; st.faces)
        foreach (k; ring)
            if (k == st.sel) { acc = add(acc, faceNormal(st, ring)); break; }
    return unit(acc);
}

private V3 dirAreaWeighted(in Stand st) {
    V3 acc = [0.0, 0.0, 0.0];
    foreach (ring; st.faces)
        foreach (k; ring)
            if (k == st.sel) {
                // un-normalized cross == twice the triangle's area
                acc = add(acc, cross(sub(st.verts[ring[1]], st.verts[ring[0]]),
                                     sub(st.verts[ring[2]], st.verts[ring[0]])));
                break;
            }
    return unit(acc);
}

private V3 dirAwayFromNeighbourCentroid(in Stand st) {
    V3 acc = [0.0, 0.0, 0.0];
    size_t n = 0;
    bool[] seen = new bool[](st.verts.length);
    foreach (ring; st.faces)
        foreach (i, k; ring)
            if (k == st.sel) {
                foreach (j; [(i + 1) % ring.length,
                             (i + ring.length - 1) % ring.length]) {
                    const uint nb = ring[j];
                    if (!seen[nb]) { seen[nb] = true; acc = add(acc, st.verts[nb]); ++n; }
                }
                break;
            }
    return unit(sub(st.verts[st.sel], scale(acc, 1.0 / n)));
}

private V3 dirNegatedMeanEdgeDirection(in Stand st) {
    V3 acc = [0.0, 0.0, 0.0];
    bool[] seen = new bool[](st.verts.length);
    foreach (ring; st.faces)
        foreach (i, k; ring)
            if (k == st.sel) {
                foreach (j; [(i + 1) % ring.length,
                             (i + ring.length - 1) % ring.length]) {
                    const uint nb = ring[j];
                    if (!seen[nb]) {
                        seen[nb] = true;
                        acc = add(acc, unit(sub(st.verts[nb], st.verts[st.sel])));
                    }
                }
                break;
            }
    return unit(scale(acc, -1.0));
}

private double angleDeg(V3 a, V3 b) {
    double c = dot(a, b);
    if (c >  1.0) c =  1.0;
    if (c < -1.0) c = -1.0;
    return acos(c) * 180.0 / PI;
}

private JSONValue fixture() { return parseJSON(readText(kFixture)); }

// ---------------------------------------------------------------------------
// The measured law reproduces every frozen apex: `shift` along the
// normalized mean of the incident faces' UNIT normals.
// ---------------------------------------------------------------------------
unittest
{
    auto fx = fixture();
    const double tol = num(fx["tolerance"]);

    int cubeCells = 0, fanCells = 0, degenerate = 0, reversedRatio = 0;
    foreach (cellV; fx["cells"].array) {
        auto cell = cellV.object;
        const string name  = cell["stand"].str;
        const double shift = num(cell["shift"]);
        const double width = num(cell["width"]);
        const V3 frozen    = vec3(cell["apex"]);

        auto st = stand(fx, name);
        const V3 origin = st.verts[st.sel];

        // The law: width == 0 gates the whole shift pass; otherwise the apex
        // moves by exactly `shift` along the mean unit normal.
        const V3 predicted = (width == 0.0)
            ? origin
            : add(origin, scale(dirMeanUnitNormals(st), shift));

        assert(dist(predicted, frozen) <= tol,
            format("apex law on %s (shift=%s width=%s): the measured law "
                 ~ "predicts (%s, %s, %s), the frozen capture says "
                 ~ "(%s, %s, %s) -- off by %s",
                   name, shift, width, predicted[0], predicted[1],
                   predicted[2], frozen[0], frozen[1], frozen[2],
                   dist(predicted, frozen)));

        // Magnitude, asserted separately so a wrong direction and a wrong
        // magnitude cannot cancel into a passing position.
        const double moved = dist(frozen, origin);
        const double want  = (width == 0.0) ? 0.0 : shift;
        assert(abs(moved - want) <= tol,
            format("apex displacement on %s (shift=%s width=%s): expected %s "
                 ~ "(the SHIFT alone), frozen capture moved %s -- "
                 ~ "shift+width would be %s", name, shift, width, want,
                   moved, shift + width));

        if (name == "cube_corner") ++cubeCells; else ++fanCells;
        if (shift == width && shift != 0.0) ++degenerate;
        if (width != 0.0 && shift != 0.0 && shift != width) ++reversedRatio;
    }

    assert(cubeCells >= 4,
        format("the cube-corner stand must keep its cells, found %d", cubeCells));
    assert(fanCells >= 3,
        format("the irregular-fan stand is the only one that separates the "
             ~ "DIRECTION candidates and must keep its cells, found %d",
               fanCells));
    assert(degenerate >= 1,
        "the shift == width cell must STAY: it is the control that stays "
        ~ "green under the refuted law, and it is the only reason we can say "
        ~ "the other cells discriminate");
    assert(reversedRatio >= 2,
        format("at least two cells with shift != width are what separate "
             ~ "`shift` from `shift+width`, `2*shift` and `2*width`; found %d",
               reversedRatio));
}

// ---------------------------------------------------------------------------
// The magnitude candidates: each must MISS on the discriminating cells and
// AGREE on the degenerate one. Without the second half this file could not
// claim the original cell was unfalsifiable -- it would merely assert it.
// ---------------------------------------------------------------------------
unittest
{
    auto fx = fixture();
    const double tol = num(fx["tolerance"]);

    double refuted(string which, double shift, double width) {
        switch (which) {
            case "apex_is_shift_plus_width": return shift + width;
            case "apex_is_twice_shift":      return 2.0 * shift;
            case "apex_is_twice_width":      return 2.0 * width;
            default: assert(false, "unknown candidate " ~ which);
        }
    }

    enum candidates = ["apex_is_shift_plus_width", "apex_is_twice_shift",
                       "apex_is_twice_width"];

    // (a) Every candidate must MISS the measurement on at least one cell.
    foreach (which; candidates) {
        assert(which in fx["refuted"].object,
            format("the fixture must keep the refutation of %s -- the "
                 ~ "candidate list IS the evidence a discriminating stand "
                 ~ "was built", which));
        bool missedSomewhere = false;
        foreach (cellV; fx["cells"].array) {
            auto cell = cellV.object;
            const double shift = num(cell["shift"]);
            const double width = num(cell["width"]);
            if (width == 0.0 || shift == 0.0) continue;   // the gate cells
            auto st = stand(fx, cell["stand"].str);
            const double moved = dist(vec3(cell["apex"]), st.verts[st.sel]);
            if (abs(refuted(which, shift, width) - moved) > tol)
                missedSomewhere = true;
        }
        assert(missedSomewhere,
            format("candidate %s is NOT refuted by any cell in this fixture "
                 ~ "-- either a discriminating cell was dropped or the "
                 ~ "refutation claim is false", which));
    }

    // (b) The degeneracy itself, stated as a check rather than a comment: on
    // the shift == width cell the three candidates are indistinguishable
    // FROM EACH OTHER (all predict the same number), so no measurement on
    // that cell -- right or wrong -- could ever have chosen between them.
    // On a discriminating cell they must come apart.
    int degenerateSeen = 0, separatingSeen = 0;
    foreach (cellV; fx["cells"].array) {
        auto cell = cellV.object;
        const double shift = num(cell["shift"]);
        const double width = num(cell["width"]);
        if (width == 0.0 || shift == 0.0) continue;
        double lo = double.max, hi = -double.max;
        foreach (which; candidates) {
            const double p = refuted(which, shift, width);
            if (p < lo) lo = p;
            if (p > hi) hi = p;
        }
        if (shift == width) {
            ++degenerateSeen;
            assert(hi - lo <= tol,
                format("the shift == width cell was supposed to be the one "
                     ~ "that cannot separate the candidates, but they spread "
                     ~ "over %s there", hi - lo));
        } else {
            ++separatingSeen;
            assert(hi - lo > tol,
                format("cell (shift=%s width=%s) is listed as discriminating "
                     ~ "but all three candidates predict the same number "
                     ~ "there -- it separates nothing", shift, width));
        }
    }
    assert(degenerateSeen >= 1 && separatingSeen >= 2,
        format("the fixture needs BOTH the degenerate control and at least "
             ~ "two separating cells; found %d and %d",
               degenerateSeen, separatingSeen));

    // (c) And the second defect, which degeneracy alone does not cover: the
    // value originally RECORDED for that degenerate cell (shift + width) is
    // not what the cell measures. It was not merely unfalsifiable, it was
    // wrong.
    foreach (cellV; fx["cells"].array) {
        auto cell = cellV.object;
        const double shift = num(cell["shift"]);
        const double width = num(cell["width"]);
        if (shift != width || shift == 0.0) continue;
        auto st = stand(fx, cell["stand"].str);
        const double moved = dist(vec3(cell["apex"]), st.verts[st.sel]);
        assert(abs(moved - (shift + width)) > tol,
            format("the shift == width cell now measures %s, which equals "
                 ~ "the originally recorded shift+width -- if that ever "
                 ~ "becomes true again, this fixture's whole correction "
                 ~ "claim is wrong and must be re-measured", moved));
    }
}

// ---------------------------------------------------------------------------
// The direction candidates, and the reason the cube cannot judge them.
// ---------------------------------------------------------------------------
unittest
{
    auto fx = fixture();
    auto cube = stand(fx, "cube_corner");
    auto fan  = stand(fx, "irregular_fan_valence4");

    const V3 measured = dirMeanUnitNormals(fan);

    // On the fan the three rivals are far away -- that is what makes it a
    // stand rather than a decoration.
    struct Rival { string key; V3 dir; double minDeg; }
    auto rivals = [
        Rival("apex_direction_is_area_weighted_normal",
              dirAreaWeighted(fan), 1.0),
        Rival("apex_direction_is_away_from_neighbour_centroid",
              dirAwayFromNeighbourCentroid(fan), 10.0),
        Rival("apex_direction_is_negated_mean_edge_direction",
              dirNegatedMeanEdgeDirection(fan), 10.0),
    ];
    foreach (r; rivals) {
        assert(r.key in fx["refuted"].object,
            format("the fixture must keep the refutation of %s", r.key));
        const double a = angleDeg(measured, r.dir);
        assert(a >= r.minDeg,
            format("direction candidate %s sits %s degrees from the measured "
                 ~ "direction on the irregular fan -- too close to have been "
                 ~ "separated; this stand no longer discriminates", r.key, a));
    }

    // And on the cube every one of them collapses onto the same ray, which
    // is the whole reason the fan exists. If this ever stops holding, the
    // comment above is wrong and someone must find out why.
    foreach (d; [dirAreaWeighted(cube), dirAwayFromNeighbourCentroid(cube)]) {
        const double a = angleDeg(dirMeanUnitNormals(cube), d);
        assert(a < 1e-6,
            format("on a cube corner this candidate was supposed to be "
                 ~ "INDISTINGUISHABLE from the measured direction, but it "
                 ~ "sits %s degrees away", a));
    }
}

// ---------------------------------------------------------------------------
// The ring, and the gate.
// ---------------------------------------------------------------------------
unittest
{
    auto fx = fixture();
    const double tol = num(fx["tolerance"]);

    bool sawGate = false, sawRing = false;
    foreach (cellV; fx["cells"].array) {
        auto cell = cellV.object;
        const double shift = num(cell["shift"]);
        const double width = num(cell["width"]);

        if (width == 0.0) {
            sawGate = true;
            auto st = stand(fx, cell["stand"].str);
            assert(dist(vec3(cell["apex"]), st.verts[st.sel]) <= tol,
                format("width == 0 (shift=%s) must be a COMPLETE no-op, but "
                     ~ "the frozen apex moved", shift));
            auto counts = cell["counts"].array;
            assert(num(counts[0]) == num(counts[2])
                && num(counts[1]) == num(counts[3]),
                format("width == 0 (shift=%s) must create no topology, but "
                     ~ "the frozen counts change", shift));
            continue;
        }

        if ("ring_radii" !in cell) continue;
        foreach (r; cell["ring_radii"].array) {
            const double got = num(r);
            // Every recorded ring radius is either the width of THIS cell or
            // that of another cell on the same stand -- what must never
            // happen is a radius that depends on the shift.
            assert(abs(got - width) <= tol || got != shift + width,
                format("ring radius %s on %s (shift=%s width=%s) matches "
                     ~ "shift+width -- the shift must not reach the ring",
                       got, cell["stand"].str, shift, width));
            sawRing = true;
        }
    }
    assert(sawGate, "the width == 0 gate cell must stay in the fixture");
    assert(sawRing, "the ring cells must stay in the fixture");

    assert(fx["provenance"]["method"].str == "command",
        "these cells are MEASUREMENTS through the reference's command lane, "
        ~ "not an evaluation of a read formula; the provenance must say so");
}
