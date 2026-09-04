// Which space a falloff's metric is evaluated in, when the edited layer
// carries a non-identity item transform.  (Task 0659, closing 0644 + 0646.)
//
// ── THE TWO READINGS ───────────────────────────────────────────────────────
//
// A layer's mesh is stored in the layer's own coordinates and drawn through
// its item matrix, so a falloff handle value ("centre at the origin, radius
// 1") can mean two self-consistent things:
//
//   (a) LAYER-LOCAL — the vertex is compared against the handles exactly as
//       both are stored.  The region of influence then stretches with the
//       layer and is an ellipsoid in WORLD.
//   (b) WORLD — the vertex is lifted by the item matrix first and the handles
//       are world coordinates.  The region stays a sphere in WORLD and looks
//       squashed in the layer's own units.
//
// The answer is (b), and it is measured, not chosen: ten cells, frozen into
// `tests/fixtures/falloff_radius_space.json`.  rms 2.4e-8 against the world
// reading, 0.380 against the layer-local one.  Three further facts came with
// it, and each has its own cell below: the handles are read in the SAME space
// as the vertex (so both MIXED readings die too); the WHOLE matrix is used and
// not just its scale part; and the ellipsoid's axes are the WORLD axes.
//
// ── HOW A WEIGHT IS RECOVERED, AND WHY IT IS NOT CIRCULAR ─────────────────
//
// There is no "read me the weights" endpoint, so the weights are recovered the
// way the capture recovered them: commit a translate under the falloff and
// read the per-vertex displacement.  For a translate, d_i = w_i * T, so
//
//     w_i = (d_i . T) / |T|^2
//
// with T taken from a falloff-FREE control run at the SAME item transform.
// Measuring T from our own control rather than reading it out of the fixture
// is deliberate: it makes this test independent of which space the TRANSFORM
// applies its numeric offset in (that is tasks 0614/0649's subject, and it has
// its own fixture next door in test_acen_item_space.d).  Whatever T turns out
// to be, the weights divide it out — so what is left is only the falloff.
//
// The recovery is only valid if every displacement really is parallel to T,
// which is asserted per case before any weight is scored.
//
// ── ANTI-VACUITY ──────────────────────────────────────────────────────────
//
// "The weights match the measured ones" is worth nothing if the REJECTED
// reading yields the same numbers on this stand, so the fixture carries both
// (`weights` and `weightsIfLayerLocal`) and every scored case asserts that
// they are still apart HERE — 0.66 on the main cell, a clean 1.0 on the
// translation-only one — before asserting which of the two we landed on.  The
// two identity control cells are exempt by construction: there the readings
// coincide, and their job is only to prove the recovery chain is exact.
//
// ── VERIFIED BY MUTATION ──────────────────────────────────────────────────
//
// Each wrong implementation below was applied to the green tree, built, and
// run; the observed failure is quoted, then the tree was restored and the
// test re-run green.  All three are readings a reasonable person would
// defend, which is the point — the first one is what the code did until now.
//
//   1. THE LAYER-LOCAL READING.  `evaluateFalloff` dispatches the eight
//      world-space kinds on the vertex AS STORED instead of the lifted one
//      (source/falloff.d, `posWorld` -> `posLocal`).
//        → scaled_radial: rms vs world = 3.801e-01 (tol 1.0e-04),
//          rms vs layer-local = 1.116e-07.
//      The recovered weights land exactly on `weightsIfLayerLocal`, which is
//      what makes this the reading the fixture was built to reject: the
//      0.3801 is the fixture's own `rmsVsLayerLocal` for that cell.
//
//   2. ONLY THE SCALE PART OF THE MATRIX.  `AimViewport.toWorld` applies the
//      linear block and drops the translation.
//        → moved_radial: rms vs world = 6.822e-01, rms vs layer-local
//          = 4.817e-08.  The scaled cells still PASS (a pure scale has no
//          translation to drop), so this mutation is caught only by the
//          translation-only cell — which is why that cell exists.
//
//   3. A MIXED READING.  The vertex is lifted but the centre is folded back
//      into the layer's coordinates, so the two ends are compared in
//      different spaces.
//        → scaled_radial_cenoff: rms vs world = 1.931e-01, rms vs
//          layer-local = 3.512e-01 — neither reading, a THIRD behaviour, as
//          two interpretations in one path always produce.  `scaled_radial`
//          PASSES under it (its centre is at the item origin, where the fold
//          is a no-op), so the off-origin cell is the one that kills it.
//
//   4. The region claim of §4b, isolated (the earlier cells abort the module
//      before it is reached, so it was run in a cut-down copy) under
//      mutation 1:
//        → "vertex E: it is drawn INSIDE the overlay (world ellipsoid
//           distance 0.550000) but it did not move (weight 0.000000000)."
//
//   5. The element-centre claim of §4c, isolated the same way, under
//      mutation 1:
//        → "vertex B: element weight 0.700000000, expected 0.999999976 from
//           the WORLD action centre (the folded-to-local centre would give
//           0.699999976)."
//      The parenthetical is the whole story: with the vertex unlifted, the
//      drag lands on the folded reading even though the drag path never
//      folded anything — mixing one world end with one local end reproduces
//      the fold exactly.
//
//   6. AUTO-SIZE FITTED TO THE LAYER-LOCAL BOX (§6), i.e. what it did before.
//        → "auto-sized centre is (0.225000, 0.550000, 0.110000), the WORLD
//           selection box centre is (0.450000, 0.275000, 0.440000) and the
//           layer-local one is (0.225000, 0.550000, 0.110000)."
//      Note for whoever mutates this next: `autoSize` and `autoSizeAxis` open
//      with the SAME four lines, so a textual patch anchored on them lands in
//      `autoSizeAxis` (which comes first in the file) and looks inert.  Anchor
//      on the `final switch (type)` that follows autoSize's copy.
//
//   7. AN INERT MUTATION, recorded because it is the useful one.  Restoring
//      the `toLocalPoint` fold on `FalloffStage.evaluate`'s published
//      `pkt.pickedCenter` leaves every cell here GREEN.  That is not a hole
//      in §4c so much as a fact about the code: `pickedCenter` has two
//      producers, and the drag path uses the OTHER one (see §4c).  The fold
//      was only ever visible in the overlay, which no headless test can see.
//
import http_client : testBaseUrl, getJson, postJson;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.conv   : to;
import std.math   : fabs, sqrt, isFinite;
import std.format : format;
import std.file   : readText;
import std.algorithm : max;

void main() {}

alias baseUrl = testBaseUrl;


void cmd(string argstring) {
    auto r = postJson("/api/command", argstring);
    assert("status" !in r || r["status"].str != "error",
           format("command %s failed: %s", argstring, r.toString()));
}

// --------------------------------------------------------------------------
// The frozen fixture.
// --------------------------------------------------------------------------
JSONValue fixture() {
    static JSONValue cached;
    static bool loaded = false;
    if (!loaded) {
        cached = parseJSON(readText("tests/fixtures/falloff_radius_space.json"));
        loaded = true;
    }
    return cached;
}

double num(JSONValue e) {
    return (e.type == JSONType.integer)  ? cast(double) e.integer
         : (e.type == JSONType.uinteger) ? cast(double) e.uinteger
                                         : e.floating;
}
double[3] vec3Of(JSONValue j) {
    double[3] v;
    foreach (i; 0 .. 3) v[i] = num(j.array[i]);
    return v;
}
double[] arrOf(JSONValue j) {
    double[] v;
    foreach (e; j.array) v ~= num(e);
    return v;
}
string vecStr(double[3] v) {
    return format("%.10g,%.10g,%.10g", v[0], v[1], v[2]);
}

// The WORLD translate every cell was captured under.  Recorded in the
// fixture's `alsoMeasured` note: the request (0.7, 0.5, 0.3) landed as the
// local (0.35, 1.0, 0.075) under scale (2, 0.5, 4) and as (0.5, -0.7, 0.3)
// under a 90-degree Z rotation.  Only its DIRECTION matters here — the weight
// recovery divides |T| out — but using the captured request keeps the stand
// numerically identical to the one that produced the frozen weights.
enum double[3] requestedOffset = [0.7, 0.5, 0.3];

// Anything below this is float32-and-JSON noise on a displacement of order
// 0.35; the smallest separation this test scores against is 0.45, three and a
// half orders of magnitude above it.
enum double weightTol = 1e-4;

// --------------------------------------------------------------------------
// The stand: the fixture's eight vertices, on a layer carrying the case's
// item transform, with every vertex selected so the moving set is the whole
// stand and the falloff is the only thing that varies a weight.
// --------------------------------------------------------------------------
void buildStand(JSONValue kase) {
    auto fx = fixture();
    postJson("/api/command", commandBody("scene.reset", "{}"));

    string verts = "[";
    foreach (i, v; fx["stand"]["vertices"].array) {
        auto p = vec3Of(v);
        verts ~= (i ? "," : "") ~ format("[%.10g,%.10g,%.10g]", p[0], p[1], p[2]);
    }
    verts ~= "]";
    auto lm = postJson("/api/command", commandBody("scene.loadMesh", format(`{"vertices":%s,"faces":[]}`, verts)));
    assert(lm["status"].str == "ok", "load-mesh failed: " ~ lm.toString());

    auto item = kase["item"];
    static immutable string[3] axes = ["x", "y", "z"];
    foreach (chan; ["pos", "rot", "scl"]) {
        auto vals = vec3Of(item[chan]);
        foreach (i; 0 .. 3)
            cmd(format("layer.attr 0 %s.%s %.10g", chan, axes[i], vals[i]));
    }

    string idx = "";
    foreach (i; 0 .. fx["stand"]["vertices"].array.length)
        idx ~= (i ? "," : "") ~ i.to!string;
    postJson("/api/command", commandBody("mesh.select", format(`{"mode":"vertices","indices":[%s]}`, idx)));
}

double[][] modelVertices() {
    auto j = getJson("/api/model");
    double[][] outV;
    foreach (v; j["vertices"].array) {
        auto p = vec3Of(v);
        outV ~= [p[0], p[1], p[2]];
    }
    return outV;
}

// Arm the falloff described by the case, if any.  `type` is set FIRST and on
// purpose: a type change runs FalloffStage.autoSize(), which overwrites
// centre/size/start/end from the selection bbox — setting the handles before
// the type would have them silently replaced.
void armFalloff(JSONValue kase) {
    if (kase["falloff"].type == JSONType.null_) return;
    auto f = kase["falloff"];
    string kind = f["kind"].str;
    cmd("tool.pipe.attr falloff type " ~ kind);
    cmd("tool.pipe.attr falloff shape " ~ f["shape"].str);
    if (kind == "radial") {
        cmd(format(`tool.pipe.attr falloff center "%s"`, vecStr(vec3Of(f["center"]))));
        cmd(format(`tool.pipe.attr falloff size "%s"`,   vecStr(vec3Of(f["size"]))));
    } else {
        cmd(format(`tool.pipe.attr falloff start "%s"`, vecStr(vec3Of(f["start"]))));
        cmd(format(`tool.pipe.attr falloff end "%s"`,   vecStr(vec3Of(f["end"]))));
    }
}

/// Run one cell and return the per-vertex LOCAL displacement.
double[][] runCase(JSONValue kase) {
    buildStand(kase);
    auto before = modelVertices();
    cmd("tool.set move");
    armFalloff(kase);
    cmd(format("tool.attr move TX %.10g", requestedOffset[0]));
    cmd(format("tool.attr move TY %.10g", requestedOffset[1]));
    cmd(format("tool.attr move TZ %.10g", requestedOffset[2]));
    cmd("tool.doApply");
    auto after = modelVertices();
    assert(before.length == after.length,
           "vertex count changed across the apply");
    double[][] d;
    foreach (i; 0 .. before.length)
        d ~= [after[i][0] - before[i][0],
              after[i][1] - before[i][1],
              after[i][2] - before[i][2]];
    return d;
}

double dot3(double[] a, double[] b) {
    return a[0]*b[0] + a[1]*b[1] + a[2]*b[2];
}

JSONValue caseNamed(string name) {
    foreach (c; fixture()["cases"].array)
        if (c["name"].str == name) return c;
    assert(false, "fixture has no case named " ~ name);
}

/// The falloff-free control that shares this case's item transform — the run
/// that supplies T.  Named by convention: every weighted cell's item
/// transform has a `*_nofalloff` (or identity-control) twin in the fixture.
string controlFor(string name) {
    if (name.length > 6 && name[0 .. 6] == "scaled") return "scaled_nofalloff";
    if (name.length > 5 && name[0 .. 5] == "moved")  return "moved_nofalloff";
    if (name.length > 3 && name[0 .. 3] == "rot")    return "rot_nofalloff";
    return "";   // identity cells: T is the requested offset itself
}

/// Recover the per-vertex weights of `name` against its own control.
double[] recoverWeights(string name, out double[3] tOut) {
    auto kase = caseNamed(name);
    string ctrlName = controlFor(name);

    double[] T;
    if (ctrlName.length) {
        auto ctrl = runCase(caseNamed(ctrlName));
        // The control carries no falloff, so every vertex takes the full
        // offset — that is what makes any one of them a valid T.  Check it,
        // rather than assume it: a control that did NOT move uniformly would
        // silently rescale every weight below.
        T = ctrl[0].dup;
        foreach (i; 1 .. ctrl.length)
            foreach (k; 0 .. 3)
                assert(fabs(ctrl[i][k] - T[k]) < 1e-5,
                    format("control %s: vertex %d displacement %g differs from "
                           ~ "vertex 0's %g on axis %d — not a uniform offset",
                           ctrlName, i, ctrl[i][k], T[k], k));
    } else {
        T = [requestedOffset[0], requestedOffset[1], requestedOffset[2]];
    }
    double t2 = dot3(T, T);
    assert(t2 > 1e-9, "control produced a zero offset — nothing to divide by");
    tOut = [T[0], T[1], T[2]];

    auto d = runCase(kase);
    double[] w;
    foreach (i; 0 .. d.length) {
        double proj = dot3(d[i], T) / t2;
        // Parallel check: the residual perpendicular to T must vanish, or the
        // projection above is not a weight at all.
        double[3] resid = [d[i][0] - proj*T[0],
                           d[i][1] - proj*T[1],
                           d[i][2] - proj*T[2]];
        double rl = sqrt(resid[0]*resid[0] + resid[1]*resid[1] + resid[2]*resid[2]);
        assert(rl < 1e-5,
            format("%s vertex %d: displacement is not parallel to T "
                   ~ "(off-axis residual %g) — the weight recovery is invalid",
                   name, i, rl));
        assert(isFinite(proj), format("%s vertex %d: non-finite weight", name, i));
        w ~= proj;
    }
    return w;
}

string[string] wghtAttrs() {
    auto j = getJson("/api/toolpipe");
    foreach (st; j["stages"].array)
        if (st["task"].str == "WGHT") {
            string[string] out_;
            foreach (k, v; st["attrs"].object) out_[k] = v.str;
            return out_;
        }
    assert(false, "WGHT stage missing from /api/toolpipe");
}

double[3] parseVec3Attr(string s) {
    import std.array : split;
    auto parts = s.split(",");
    assert(parts.length == 3, "expected an \"x,y,z\" attr, got: " ~ s);
    double[3] v;
    foreach (i; 0 .. 3) v[i] = parts[i].to!double;
    return v;
}

double maxAbsDiff3(double[3] a, double[3] b) {
    double m = 0;
    foreach (i; 0 .. 3) m = max(m, fabs(a[i] - b[i]));
    return m;
}

string fmt3(double[3] v) {
    return format("%.6f, %.6f, %.6f", v[0], v[1], v[2]);
}

double rms(double[] a, double[] b) {
    double s = 0;
    foreach (i; 0 .. a.length) { double e = a[i] - b[i]; s += e*e; }
    return sqrt(s / a.length);
}
double maxAbs(double[] a, double[] b) {
    double m = 0;
    foreach (i; 0 .. a.length) m = max(m, fabs(a[i] - b[i]));
    return m;
}
string fmtW(double[] w) {
    string s = "[";
    foreach (i, v; w) s ~= (i ? ", " : "") ~ format("%.6f", v);
    return s ~ "]";
}

/// Score one cell: the readings must still be apart on this stand, and we must
/// have landed on the WORLD one.
void scoreCase(string name, double minSeparation) {
    auto kase   = caseNamed(name);
    auto world  = arrOf(kase["weights"]);
    auto local  = arrOf(kase["weightsIfLayerLocal"]);
    auto names  = fixture()["stand"]["vertexNames"].array;

    // --- anti-vacuity, FIRST: a stand where the two readings coincide would
    // make every assertion below pass for free. ---
    double sep = maxAbs(world, local);
    assert(sep >= minSeparation - 1e-6,
        format("%s: the fixture's two readings are only %.6f apart on this "
               ~ "stand (expected >= %.6f) — this cell no longer discriminates "
               ~ "and asserting against it would measure nothing",
               name, sep, minSeparation));

    double[3] T;
    auto got = recoverWeights(name, T);
    assert(got.length == world.length,
        format("%s: recovered %d weights, fixture has %d",
               name, got.length, world.length));

    double rWorld = rms(got, world);
    double rLocal = rms(got, local);
    assert(rWorld < weightTol,
        format("%s: recovered weights are not the MEASURED (world) ones.\n"
               ~ "  recovered  %s\n  world      %s\n  layer-local %s\n"
               ~ "  rms vs world = %.3e (tol %.1e), rms vs layer-local = %.3e\n"
               ~ "  T = (%.6f, %.6f, %.6f)",
               name, fmtW(got), fmtW(world), fmtW(local),
               rWorld, weightTol, rLocal, T[0], T[1], T[2]));
    // ...and it is not merely "closer to" world: the rejected reading must be
    // decisively refused, by the separation the fixture recorded.
    assert(rLocal > 10 * weightTol,
        format("%s: the layer-local reading fits just as well (rms %.3e) — "
               ~ "the cell has collapsed", name, rLocal));

    // Per-vertex, so a failure names the vertex rather than an aggregate.
    foreach (i; 0 .. got.length)
        assert(fabs(got[i] - world[i]) < weightTol,
            format("%s vertex %s: weight %.9f, measured %.9f "
                   ~ "(the layer-local reading would give %.9f)",
                   name, names[i].str, got[i], world[i], local[i]));
}

// ==========================================================================
// 0. The recovery chain itself, on an identity item transform.
//    Both readings coincide here by construction, so this cell proves only
//    that the chain is exact — and it has to, or a failure anywhere below
//    would be ambiguous between "wrong space" and "broken measurement".
// ==========================================================================
unittest {
    foreach (name; ["ctrl_identity_radial", "ctrl_identity_linear"]) {
        auto kase  = caseNamed(name);
        auto world = arrOf(kase["weights"]);
        auto local = arrOf(kase["weightsIfLayerLocal"]);
        assert(maxAbs(world, local) < 1e-6,
            name ~ ": identity control must have the two readings COINCIDE — "
            ~ "if they differ, this is not a control");
        double[3] T;
        auto got = recoverWeights(name, T);
        assert(rms(got, world) < weightTol,
            format("%s: the recovery chain is not exact — %s vs %s",
                   name, fmtW(got), fmtW(world)));
    }
}

// ==========================================================================
// 1. THE QUESTION: a non-uniform scale differing on all three axes, an
//    isotropic radius, and the centre at the item origin — so the centre is
//    the same point in both spaces and only the VERTEX lift is under test.
// ==========================================================================
unittest {
    scoreCase("scaled_radial", 0.659999996);
}

// ==========================================================================
// 2. The handles are read in the SAME space as the vertex.
//    With the centre off the item origin, the two MIXED readings (lift the
//    vertex but not the centre, or the other way round) stop agreeing with
//    either pure reading — so this cell is what kills them.
// ==========================================================================
unittest {
    scoreCase("scaled_radial_cenoff", 0.453739989);
}

// ==========================================================================
// 3. A second, independent falloff KIND under the same scale.  If the law
//    were a quirk of one kind's arithmetic, this cell would disagree.
// ==========================================================================
unittest {
    scoreCase("scaled_linear", 0.449999988);
}

// ==========================================================================
// 4. The WHOLE matrix is used, not just its scale part.
//    A translation-only item: the layer-local reading predicts the identity
//    weights, the world reading puts every vertex outside the unit sphere, so
//    nothing moves at all.  A binary separator worth a full 1.0 of weight —
//    and the `moved_nofalloff` control run inside `recoverWeights` is the
//    proof that the apply itself works at this transform, so "nothing moved"
//    cannot be mistaken for "nothing happened".
// ==========================================================================
unittest {
    scoreCase("moved_radial", 1.0);
}

// ==========================================================================
// 4b. THE REGION THAT IS DRAWN IS THE REGION THAT MOVES.
//
//     The fixture pins the weights; this pins the thing a user can actually
//     see.  `falloff_render.d` draws the radial overlay by projecting
//     `cfg.center` and `cfg.center +- cfg.size` through the plain WORLD
//     viewport, so the ellipsoid on screen is the world one.  A vertex drawn
//     inside it must therefore MOVE, and a vertex drawn outside must not —
//     which is only true if the weight is evaluated in world too.  That
//     agreement is task 0646: the same six fields were written in world and
//     read in the layer's own coordinates, so the outline and the moving set
//     could disagree.
//
//     Anti-vacuity: on this stand exactly one vertex (E) changes SIDE
//     between the two readings — local distance 1.1 (outside) against world
//     distance 0.55 (inside).  Without such a vertex the in/out claim would
//     hold under both readings and prove nothing, so its existence is
//     asserted before its side is.
// ==========================================================================
unittest {
    auto kase = caseNamed("scaled_radial");
    auto fx   = fixture();
    auto M    = arrOf(kase["matrix"]);
    auto cen  = vec3Of(kase["falloff"]["center"]);
    auto siz  = vec3Of(kase["falloff"]["size"]);
    auto names = fx["stand"]["vertexNames"].array;

    // Ellipsoid distance of a point, in either space.
    double ellipDist(double[3] p) {
        double s = 0;
        foreach (k; 0 .. 3) { double u = (p[k] - cen[k]) / siz[k]; s += u*u; }
        return sqrt(s);
    }
    double[3] toWorld(double[3] p) {
        double[3] q;
        foreach (r; 0 .. 3)
            q[r] = M[0*4+r]*p[0] + M[1*4+r]*p[1] + M[2*4+r]*p[2] + M[12+r];
        return q;
    }

    // --- the side-flip that makes this cell informative ---
    int flips = 0;
    foreach (v; fx["stand"]["vertices"].array) {
        auto local = vec3Of(v);
        if ((ellipDist(local) < 1.0) != (ellipDist(toWorld(local)) < 1.0))
            flips++;
    }
    assert(flips > 0,
        "no vertex changes side between the two readings on this stand — "
        ~ "the in/out claim below would hold under either and measure nothing");

    double[3] T;
    auto got = recoverWeights("scaled_radial", T);
    foreach (i, v; fx["stand"]["vertices"].array) {
        auto local  = vec3Of(v);
        double dWorld = ellipDist(toWorld(local));
        bool drawnInside = dWorld < 1.0;
        bool moved       = got[i] > weightTol;
        assert(drawnInside == moved,
            format("vertex %s: it is drawn %s the overlay (world ellipsoid "
                   ~ "distance %.6f) but it %s (weight %.9f). The outline and "
                   ~ "the moving set must be the same region.",
                   names[i].str, drawnInside ? "INSIDE" : "outside", dWorld,
                   moved ? "MOVED" : "did not move", got[i]));
    }
}

// ==========================================================================
// 4c. THE ELEMENT SPHERE'S CENTRE IS READ WHERE ACEN WRITES IT.
//
//     A CONSISTENCY guard, not a measured cell — say so plainly: the capture
//     covered the radial and linear kinds, so the numbers below are DERIVED
//     from the law those cells fixed ("the handles are read in the same space
//     as the vertex"), not independently observed.  It extends that law to
//     the element kind, whose centre comes from ACEN rather than from a typed
//     handle.
//
//     WHAT IT DOES NOT COVER, because a mutation proved it: `pickedCenter`
//     has TWO producers.  The drag path — the one this test exercises, and
//     the one a user feels — takes ACEN's centre RAW in
//     `TransformTool.captureFalloffForDrag` (transform.d), world, never
//     folded.
//     `FalloffStage.evaluate` publishes its own copy, and THAT one used to be
//     folded to layer-local; its only consumer is the OVERLAY
//     (falloff_render.d), which draws it through the world viewport.  So the
//     fold's whole effect was to separate the drawn sphere from the sphere
//     that moves geometry, on any transformed layer — exactly the seam 0646
//     names, and exactly what the old comment predicted would happen.
//     Restoring the fold does NOT turn this cell red (verified), because the
//     overlay has no headless probe; the fold's removal is carried by the
//     rendering path, which nothing here can see.  Stated rather than left
//     for someone to discover by breaking it and seeing green.
//
//     The centre is placed EXPLICITLY as a world point rather than left to
//     ACEN's own mode, so the assertion is about the space the field is read
//     in and not about how ACEN chooses a centre (that is 0649's subject).
// ==========================================================================
unittest {
    auto fx    = fixture();
    auto kase  = caseNamed("scaled_radial");   // reused for its item transform
    auto M     = arrOf(kase["matrix"]);
    auto names = fx["stand"]["vertexNames"].array;

    enum double[3] worldCentre = [0.6, 0.0, 0.0];
    enum double    radius      = 1.0;

    double[3] toWorld(double[3] p) {
        double[3] q;
        foreach (r; 0 .. 3)
            q[r] = M[0*4+r]*p[0] + M[1*4+r]*p[1] + M[2*4+r]*p[2] + M[12+r];
        return q;
    }

    buildStand(kase);
    auto before = modelVertices();
    cmd("tool.set move");
    cmd("tool.pipe.attr falloff type element");
    cmd("tool.pipe.attr falloff shape linear");
    cmd(format(`tool.pipe.attr actionCenter userPlacedCenter "%.10g,%.10g,%.10g"`,
               worldCentre[0], worldCentre[1], worldCentre[2]));
    cmd(format("tool.pipe.attr falloff dist %.10g", radius));
    cmd(format("tool.attr move TX %.10g", requestedOffset[0]));
    cmd(format("tool.attr move TY %.10g", requestedOffset[1]));
    cmd(format("tool.attr move TZ %.10g", requestedOffset[2]));
    cmd("tool.doApply");
    auto after = modelVertices();

    // T from the falloff-free control at the SAME item transform, exactly as
    // the scored cells do.
    auto ctrl = runCase(caseNamed("scaled_nofalloff"));
    double[] T = ctrl[0].dup;
    double t2 = dot3(T, T);
    assert(t2 > 1e-9, "control produced a zero offset");

    // The two readings of the centre, and the gap between them on this stand.
    double[3] foldedCentre;               // what toLocalPoint would have given
    foreach (k; 0 .. 3) foldedCentre[k] = worldCentre[k] / [2.0, 0.5, 4.0][k];
    double wExpected(double[3] q, double[3] cen) {
        double s = 0;
        foreach (k; 0 .. 3) { double u = q[k] - cen[k]; s += u*u; }
        double t = sqrt(s) / radius;
        return (t >= 1.0) ? 0.0 : 1.0 - t;
    }

    double[] mine, folded, got;
    foreach (i, v; fx["stand"]["vertices"].array) {
        auto q = toWorld(vec3Of(v));
        mine   ~= wExpected(q, worldCentre);
        folded ~= wExpected(q, foldedCentre);
        double[] d = [after[i][0] - before[i][0],
                      after[i][1] - before[i][1],
                      after[i][2] - before[i][2]];
        got ~= dot3(d, T) / t2;
    }

    // --- anti-vacuity: the fold must actually change the answer here ---
    assert(maxAbs(mine, folded) > 0.1,
        format("the removed fold makes no difference on this stand (max %.6f) "
               ~ "— the guard would pass with the fold restored",
               maxAbs(mine, folded)));

    foreach (i; 0 .. got.length)
        assert(fabs(got[i] - mine[i]) < 1e-3,
            format("vertex %s: element weight %.9f, expected %.9f from the "
                   ~ "WORLD action centre (the folded-to-local centre would "
                   ~ "give %.9f)",
                   names[i].str, got[i], mine[i], folded[i]));
}

// ==========================================================================
// 5. The ellipsoid's axes are the WORLD axes.
//    A sphere is blind to rotation, so this cell uses an ANISOTROPIC radius
//    under a rotation-only item.  Under the world reading the B/D vertex pair
//    exchanges weights; the vertices on the axis where both readings agree
//    stay put as an in-cell control.
// ==========================================================================
unittest {
    scoreCase("rot_radial_aniso", 0.674999982);

    // The exchange, named rather than left inside the aggregate: B lies on
    // +X and D on +Y, the radius is (0.5, 2, 2), and the item turns 90 deg
    // about Z.  If the ellipsoid were carried around BY the layer, B would
    // keep the tight 0.5 axis and read 0.4; it reads 0.85 instead, which is
    // what D reads under the layer-local reading — the pair has swapped.
    auto kase  = caseNamed("rot_radial_aniso");
    auto world = arrOf(kase["weights"]);
    auto local = arrOf(kase["weightsIfLayerLocal"]);
    assert(fabs(world[1] - local[3]) < 1e-6 && fabs(world[3] - local[1]) < 1e-6,
        format("the B/D pair must be an EXCHANGE for this cell to test the "
               ~ "ellipsoid's axes: world B=%.6f D=%.6f, layer-local B=%.6f "
               ~ "D=%.6f", world[1], world[3], local[1], local[3]));
    // F and G lie on +Z, the axis a 90-degree Z rotation leaves alone: both
    // readings agree there, so they are the in-cell control.
    assert(fabs(world[5] - local[5]) < 1e-6 && fabs(world[6] - local[6]) < 1e-6,
        "F/G lie on the rotation axis and must read the same under both "
        ~ "readings — they are this cell's in-cell control");
}
// ==========================================================================
// 6. AUTO-SIZE FITS THE WORLD BOX.
//
//     The other half of the seam, and the write side of it.  `autoSize()`
//     runs on a falloff type change and pre-fits centre/size (or start/end)
//     to the selection's bounding box.  It used to fit the box in the
//     layer's OWN coordinates, which made it the single writer of these
//     fields that disagreed with all the others — the handle drags, the
//     action centre and the overlay are world.  With the weight now measured
//     in world, a local fit would place the region of influence off the very
//     geometry it was fitted to on any transformed layer.
//
//     Directly observable: the fitted values are published as WGHT stage
//     attrs, so this reads them back rather than inferring them from motion.
//
//     Anti-vacuity is structural here — the two candidate boxes are computed
//     side by side below and asserted to differ before either is matched.
// ==========================================================================
unittest {
    auto fx   = fixture();
    auto kase = caseNamed("scaled_radial");   // reused for its item transform
    auto M    = arrOf(kase["matrix"]);

    double[3] toWorld(double[3] p) {
        double[3] q;
        foreach (r; 0 .. 3)
            q[r] = M[0*4+r]*p[0] + M[1*4+r]*p[1] + M[2*4+r]*p[2] + M[12+r];
        return q;
    }

    // The two candidate fits, from the same eight vertices.
    double[3] lMin, lMax, wMin, wMax;
    bool first = true;
    foreach (v; fx["stand"]["vertices"].array) {
        auto p = vec3Of(v);
        auto q = toWorld(p);
        if (first) { lMin = p; lMax = p; wMin = q; wMax = q; first = false; }
        foreach (k; 0 .. 3) {
            if (p[k] < lMin[k]) lMin[k] = p[k];
            if (p[k] > lMax[k]) lMax[k] = p[k];
            if (q[k] < wMin[k]) wMin[k] = q[k];
            if (q[k] > wMax[k]) wMax[k] = q[k];
        }
    }
    double[3] lCen, lHalf, wCen, wHalf;
    foreach (k; 0 .. 3) {
        lCen[k]  = (lMin[k] + lMax[k]) * 0.5;
        lHalf[k] = (lMax[k] - lMin[k]) * 0.5;
        wCen[k]  = (wMin[k] + wMax[k]) * 0.5;
        wHalf[k] = (wMax[k] - wMin[k]) * 0.5;
    }
    assert(maxAbsDiff3(lCen, wCen) > 0.1 && maxAbsDiff3(lHalf, wHalf) > 0.1,
        "the local and world fits coincide on this stand — nothing to test");

    buildStand(kase);
    cmd("tool.set move");
    cmd("tool.pipe.attr falloff type radial");   // this is what runs autoSize

    auto a = wghtAttrs();
    double[3] gotCen  = parseVec3Attr(a["center"]);
    double[3] gotSize = parseVec3Attr(a["size"]);

    assert(maxAbsDiff3(gotCen, wCen) < 1e-4,
        format("auto-sized centre is (%s), the WORLD selection box centre is "
               ~ "(%s) and the layer-local one is (%s)",
               fmt3(gotCen), fmt3(wCen), fmt3(lCen)));
    assert(maxAbsDiff3(gotSize, wHalf) < 1e-4,
        format("auto-sized radii are (%s), the WORLD selection box half-"
               ~ "extents are (%s) and the layer-local ones are (%s)",
               fmt3(gotSize), fmt3(wHalf), fmt3(lHalf)));
}
