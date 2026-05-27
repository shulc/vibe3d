module fixture_helpers;

// Golden-fixture harness for "frozen state" tests.
//
// The idea (vibe3d-only, no external engine at test time): a fixture JSON
// carries an ordered list of HTTP setup steps plus the *expected* mesh
// state after them. A test embeds the fixture (via `-J=tests` string
// import) and calls runFixture() — which drives the steps against a live
// vibe3d and asserts every vertex of /api/model against the golden.
//
// Where the golden comes from is the fixture author's concern, recorded
// in its "source" field: hand-authored/analytic for axis-aligned cases,
// or a frozen reference capture for parity cases. Either way the test runs
// without any external reference engine.
//
// Fixture schema:
//   {
//     "name":        "<id>",
//     "description": "...",
//     "source":      "...",            // provenance of the golden
//     "tolerance":   1e-4,             // optional, default 1e-4
//     "setup": [                        // ordered HTTP steps
//       { "endpoint": "reset" },
//       { "endpoint": "select",  "body": { ... } },
//       { "endpoint": "command", "body": { "id": "...", "params": {...} } }
//     ],
//     "expected": { "vertices": [ [x,y,z], ... ] }
//   }
//
// "endpoint" is a shorthand mapped to an /api/* path below. Mutating
// endpoints answer {"status":"ok"|"error"}; an explicit "error" aborts
// the test with the server message.
//
// NB: the literal "localhost:8080" is rewritten per-worker by run_test.d
// for parallel runs — keep it spelled out, do not build it dynamically.

import std.json;
import std.net.curl : get, post;
import std.math : fabs, PI;
import std.format : format;

private enum string BASE = "http://localhost:8080";

private string endpointPath(string ep) {
    switch (ep) {
        case "reset":     return BASE ~ "/api/reset";
        case "select":    return BASE ~ "/api/select";
        case "command":   return BASE ~ "/api/command";
        case "transform": return BASE ~ "/api/transform";
        case "script":    return BASE ~ "/api/script";
        default: assert(false, "fixture: unknown setup endpoint '" ~ ep ~ "'");
    }
}

// JSON numbers may parse as integer, uinteger, or float_ depending on how
// the literal was written ("0" vs "0.0"). Coerce uniformly so a golden of
// [0, 0, 0] compares the same as [0.0, 0.0, 0.0].
private double asDouble(JSONValue v) {
    final switch (v.type) {
        case JSONType.float_:    return v.floating;
        case JSONType.integer:   return cast(double) v.integer;
        case JSONType.uinteger:  return cast(double) v.uinteger;
        case JSONType.string:    case JSONType.array:  case JSONType.object:
        case JSONType.true_:     case JSONType.false_: case JSONType.null_:
            assert(false, "fixture: expected a number, got " ~ v.toString);
    }
}

// Execute one setup/input/op step. A step is either
//   { "endpoint": "...", "body": { ... } }      → POST the JSON body
//   { "endpoint": "command", "argstring": "..." } → POST the raw argstring
//   { "endpoint": "reset" }                       → POST with empty body
// Mutating endpoints answer {"status":"ok"|"error"}; "error" aborts.
private void postStep(JSONValue step, string name, string phase, size_t i) {
    string ep = step["endpoint"].str;
    string body = ("argstring" in step) ? step["argstring"].str
                : ("body"      in step) ? step["body"].toString
                : "";
    auto resp = cast(string) post(endpointPath(ep), body);
    if (resp.length && resp[0] == '{') {
        auto j = parseJSON(resp);
        if ("status" in j && j["status"].str == "error")
            assert(false, format("%s: %s step %d (%s) failed: %s",
                                 name, phase, i, ep, resp));
    }
}

// GET /api/model and return its vertices as an array of [x,y,z].
private double[3][] readVertices() {
    auto model = parseJSON(cast(string) get(BASE ~ "/api/model"));
    auto arr = model["vertices"].array;
    auto outv = new double[3][](arr.length);
    foreach (i, v; arr) {
        auto c = v.array;
        outv[i] = [asDouble(c[0]), asDouble(c[1]), asDouble(c[2])];
    }
    return outv;
}

private double dist2(double[3] a, double[3] b) {
    double dx = a[0]-b[0], dy = a[1]-b[1], dz = a[2]-b[2];
    return dx*dx + dy*dy + dz*dz;
}

private enum double COORD_EPS = 1e-4;
private bool veq(double[3] a, double[3] b) { return dist2(a, b) <= COORD_EPS*COORD_EPS; }
private double[3] jvec3(JSONValue v) {
    auto c = v.array; return [asDouble(c[0]), asDouble(c[1]), asDouble(c[2])];
}

// POST an argstring to /api/command; assert {"status":"ok"}.
private void cmd(string argstring, string ctx) {
    auto resp = cast(string) post(BASE ~ "/api/command", argstring);
    auto j = parseJSON(resp);
    if ("status" !in j || j["status"].str != "ok")
        assert(false, format("%s: command `%s` failed: %s", ctx, argstring, resp));
}

// Resolve coordinate-specs to vibe3d element indices for `mode`, reading the
// current /api/model. Lets a fixture select by geometry (engine-neutral)
// instead of hard-coded indices, and works on any mesh. Spec shapes:
//   vertices : [x,y,z]
//   edges    : [[x,y,z],[x,y,z]]            (endpoints, any order)
//   polygons : [[x,y,z], ...]               (the face's vertex coords, any order)
private int[] resolveCoords(string mode, JSONValue coordsArr, string ctx) {
    auto model = parseJSON(cast(string) get(BASE ~ "/api/model"));
    auto V = model["vertices"].array;
    double[3] vpos(long i) { return jvec3(V[cast(size_t)i]); }
    int[] outIdx;
    foreach (spec; coordsArr.array) {
        int hit = -1;
        final switch (mode) {
        case "vertices":
            // Select ALL verts at this position — some primitives (e.g. a
            // segmented box) leave coincident un-welded duplicates at seams,
            // and every duplicate must move with the selection.
            double[3] t = jvec3(spec);
            bool any = false;
            foreach (i, _; V) if (veq(vpos(i), t)) { outIdx ~= cast(int)i; any = true; }
            assert(any, format("%s: no vertex at %s", ctx, spec.toString));
            continue;
        case "edges":
            auto pr = spec.array;
            double[3] a = jvec3(pr[0]), b = jvec3(pr[1]);
            foreach (i, e; model["edges"].array) {
                auto ee = e.array;
                double[3] ea = vpos(ee[0].integer), eb = vpos(ee[1].integer);
                if ((veq(ea,a) && veq(eb,b)) || (veq(ea,b) && veq(eb,a))) {
                    hit = cast(int)i; break;
                }
            }
            break;
        case "polygons":
            auto want = spec.array;
            foreach (i, f; model["faces"].array) {
                auto fv = f.array;
                if (fv.length != want.length) continue;
                auto used = new bool[](fv.length);
                bool ok = true;
                foreach (wc; want) {
                    double[3] t = jvec3(wc); bool found = false;
                    foreach (k, fi; fv)
                        if (!used[k] && veq(vpos(fi.integer), t)) {
                            used[k] = true; found = true; break;
                        }
                    if (!found) { ok = false; break; }
                }
                if (ok) { hit = cast(int)i; break; }
            }
            break;
        }
        assert(hit >= 0,
            format("%s: no %s element at %s", ctx, mode, spec.toString));
        outIdx ~= hit;
    }
    return outIdx;
}

// Run one fixture step. Engine-neutral logical steps keep a case authored once:
//   { "reset": true }
//   { "select": { "mode": "vertices|edges|polygons", "coords": [ ... ] } }
//   { "translate": [dx, dy, dz] }     // move tool  (empty sel => whole mesh)
//   { "rotate":    [rx, ry, rz] }     // rotate tool, per-axis Euler degrees
//   { "scale":     [sx, sy, sz] }     // scale tool, per-axis factors (1=identity)
//   { "rotate_about": {"axis":[x,y,z], "angle_deg":θ, "pivot":[x,y,z]} }
//                                     // explicit rigid rotation via /api/transform
//   { "scale_about":  {"factor":[sx,sy,sz], "pivot":[x,y,z]} }
//                                     // explicit scale via /api/transform
// translate/rotate/scale run the matching tool about the default action center.
// An { "endpoint": ... } step is the low-level escape hatch (see postStep).
private void runStep(JSONValue step, string name, string phase, size_t i) {
    string ctx = format("%s: %s step %d", name, phase, i);
    if ("reset" in step) {
        post(BASE ~ "/api/reset", "");
    } else if ("select" in step) {
        auto sel    = step["select"];
        string mode = sel["mode"].str;
        int[] idx   = ("coords" in sel) ? resolveCoords(mode, sel["coords"], ctx) : [];
        string idxJson = "[";
        foreach (k, v; idx) { if (k) idxJson ~= ","; idxJson ~= format("%d", v); }
        idxJson ~= "]";
        auto resp = cast(string) post(BASE ~ "/api/select",
            format(`{"mode":"%s","indices":%s}`, mode, idxJson));
        auto j = parseJSON(resp);
        if ("status" !in j || j["status"].str != "ok")
            assert(false, format("%s: select failed: %s", ctx, resp));
    } else if ("translate" in step) {
        auto d = jvec3(step["translate"]);
        cmd("tool.set move on", ctx);
        cmd(format("tool.attr move TX %g", d[0]), ctx);
        cmd(format("tool.attr move TY %g", d[1]), ctx);
        cmd(format("tool.attr move TZ %g", d[2]), ctx);
        cmd("tool.doApply", ctx);
        cmd("tool.set move off", ctx);
    } else if ("rotate" in step) {
        // Per-axis Euler degrees about the action-axis basis, applied X→Y→Z
        // about the default action center (see XfrmTransformTool.applyHeadless).
        auto d = jvec3(step["rotate"]);
        cmd("tool.set rotate on", ctx);
        cmd(format("tool.attr rotate RX %g", d[0]), ctx);
        cmd(format("tool.attr rotate RY %g", d[1]), ctx);
        cmd(format("tool.attr rotate RZ %g", d[2]), ctx);
        cmd("tool.doApply", ctx);
        cmd("tool.set rotate off", ctx);
    } else if ("scale" in step) {
        // Per-axis factors (1 = identity) about the default action center.
        auto d = jvec3(step["scale"]);
        cmd("tool.set scale on", ctx);
        cmd(format("tool.attr scale SX %g", d[0]), ctx);
        cmd(format("tool.attr scale SY %g", d[1]), ctx);
        cmd(format("tool.attr scale SZ %g", d[2]), ctx);
        cmd("tool.doApply", ctx);
        cmd("tool.set scale off", ctx);
    } else if ("rotate_about" in step) {
        // Rotate the selection by an EXPLICIT angle about an EXPLICIT axis
        // through an EXPLICIT pivot, via the /api/transform primitive. Used
        // by reference-parity fixtures that freeze a rigid rotation recovered
        // from a captured drag (axis/angle/pivot extracted by Kabsch), so the
        // test pins vibe3d's rotation math independent of any gizmo/action-
        // center pivot policy. angle is degrees.
        auto r = step["rotate_about"];
        auto ax = jvec3(r["axis"]);
        auto pv = jvec3(r["pivot"]);
        double rad = asDouble(r["angle_deg"]) * (PI / 180.0);
        auto resp = cast(string) post(BASE ~ "/api/transform",
            format(`{"kind":"rotate","axis":[%.10g,%.10g,%.10g],"angle":%.10g,`
                   ~ `"pivot":[%.10g,%.10g,%.10g]}`,
                   ax[0], ax[1], ax[2], rad, pv[0], pv[1], pv[2]));
        auto j = parseJSON(resp);
        if ("status" !in j || j["status"].str != "ok")
            assert(false, format("%s: rotate_about failed: %s", ctx, resp));
    } else if ("scale_about" in step) {
        // Scale the selection by per-axis factors about an EXPLICIT pivot, via
        // the /api/transform primitive. Used by scale-parity fixtures: the
        // reference engine's headless xfrm.scale pivots at the world origin, so
        // the fixtures pass pivot [0,0,0] — an engine-agnostic scale (no gizmo /
        // action-center policy involved, no recovery needed).
        auto s = step["scale_about"];
        auto fac = jvec3(s["factor"]);
        auto pv = jvec3(s["pivot"]);
        auto resp = cast(string) post(BASE ~ "/api/transform",
            format(`{"kind":"scale","factor":[%.10g,%.10g,%.10g],`
                   ~ `"pivot":[%.10g,%.10g,%.10g]}`,
                   fac[0], fac[1], fac[2], pv[0], pv[1], pv[2]));
        auto j = parseJSON(resp);
        if ("status" !in j || j["status"].str != "ok")
            assert(false, format("%s: scale_about failed: %s", ctx, resp));
    } else if ("falloff_transform" in step) {
        // Weighted (falloff) single-axis transform via the LIVE tool — mirrors
        // the reference engine's numeric capture (tool.set + tool.pipe.attr
        // falloff + tool.attr <ATTR> + tool.doApply, about the default action
        // center). `value` is the recovered BASE amount (the fully-weighted,
        // w=1 transform); vibe3d's attrs are unscaled, so it's the same amount
        // the reference engine actually applied. `start`/`end` are vibe3d-native
        // handle POINTS that the gen RECOVERED from the captured weighting (the
        // reference engine's own falloff axis convention differs), so vibe3d's
        // linearWeight reproduces the same per-vertex weights.
        auto ft   = step["falloff_transform"];
        string tl = ft["tool"].str;          // move|scale|rotate
        string at = ft["attr"].str;          // TX|TY|TZ|SX|SY|SZ|RX|RY|RZ
        double vv = asDouble(ft["value"]);
        auto fo   = ft["falloff"];
        cmd(format("tool.set %s on", tl), ctx);
        cmd(format("tool.pipe.attr falloff type %s", fo["type"].str), ctx);
        cmd(format("tool.pipe.attr falloff shape %s",
                   ("shape" in fo) ? fo["shape"].str : "linear"), ctx);
        // Custom-shape Bezier tangents (default 0.5 in vibe3d, so they MUST be
        // passed explicitly when the case specifies them or the curve is wrong).
        if ("in" in fo)
            cmd(format("tool.pipe.attr falloff in %g", asDouble(fo["in"])), ctx);
        if ("out" in fo)
            cmd(format("tool.pipe.attr falloff out %g", asDouble(fo["out"])), ctx);
        if (fo["type"].str == "radial") {
            auto c = jvec3(fo["center"]);
            auto s = jvec3(fo["size"]);
            cmd(format(`tool.pipe.attr falloff center "%g,%g,%g"`,
                       c[0], c[1], c[2]), ctx);
            cmd(format(`tool.pipe.attr falloff size "%g,%g,%g"`,
                       s[0], s[1], s[2]), ctx);
        } else {
            auto a = jvec3(fo["start"]);
            auto b = jvec3(fo["end"]);
            cmd(format(`tool.pipe.attr falloff start "%g,%g,%g"`,
                       a[0], a[1], a[2]), ctx);
            cmd(format(`tool.pipe.attr falloff end "%g,%g,%g"`,
                       b[0], b[1], b[2]), ctx);
        }
        cmd(format("tool.attr %s %s %g", tl, at, vv), ctx);
        cmd("tool.doApply", ctx);
        cmd(format("tool.set %s off", tl), ctx);
    } else if ("endpoint" in step) {
        postStep(step, name, phase, i);
    } else {
        assert(false, format("%s: unrecognized step %s", ctx, step.toString));
    }
}

/// Run a frozen-state fixture given as its JSON text. Executes the setup
/// steps against a live vibe3d, then asserts /api/model's vertices match
/// `expected.vertices` within tolerance. Asserts (with a diagnostic) on
/// the first mismatch — count, per-vertex, or a failed setup step.
void runFixture(string fixtureJson) {
    auto fx     = parseJSON(fixtureJson);
    string name = ("name" in fx) ? fx["name"].str : "<unnamed>";
    double tol  = ("tolerance" in fx) ? asDouble(fx["tolerance"]) : 1e-4;

    // ---- setup ----------------------------------------------------------
    foreach (i, step; fx["setup"].array)
        postStep(step, name, "setup", i);

    // ---- compare against golden -----------------------------------------
    auto model = parseJSON(cast(string) get(BASE ~ "/api/model"));
    auto got   = model["vertices"].array;
    auto want  = fx["expected"]["vertices"].array;

    assert(got.length == want.length,
        format("%s: vertex count mismatch — expected %d, got %d",
               name, want.length, got.length));

    foreach (vi; 0 .. want.length) {
        auto w = want[vi].array;
        auto g = got[vi].array;
        foreach (c; 0 .. 3) {
            double wv = asDouble(w[c]);
            double gv = asDouble(g[c]);
            assert(fabs(wv - gv) <= tol,
                format("%s: v%d[%d] expected %.6f, got %.6f (tol %.1e)",
                       name, vi, c, wv, gv, tol));
        }
    }
}

/// Run a reference-parity fixture: a golden captured once from an external
/// reference modeling tool, frozen, and replayed against vibe3d WITHOUT that
/// tool at runtime. Because the reference engine's vertex order differs from
/// vibe3d's, the golden is stored as `before`/`after` coordinate pairs (the
/// reference's pre- and post-op positions, any order) and correspondence is
/// resolved by matching each vibe3d vertex's pre-op position to a pair's
/// `before`. Steps are engine-neutral logical steps (see runStep) so a case
/// is authored once and shared with the reference-capture tooling. Schema:
///   {
///     "name": "...", "source": "frozen reference capture", "tolerance": 1e-3,
///     "input": [ {"reset":true}, {"select":{"mode":..,"coords":[..]}} ],
///     "op":    [ {"translate":[dx,dy,dz]} ],
///     "expected_pairs": [ {"before":[x,y,z], "after":[x,y,z]}, ... ]
///   }
/// Both engines must start from the same primitive (the reference's unit cube
/// and vibe3d's makeCube are both ±0.5), else the before-match fails loudly.
void runParityFixture(string fixtureJson) {
    auto fx     = parseJSON(fixtureJson);
    string name = ("name" in fx) ? fx["name"].str : "<unnamed>";
    double tol  = ("tolerance" in fx) ? asDouble(fx["tolerance"]) : 1e-3;
    runOneParity(name, tol, fx["input"], fx["op"], fx["expected_pairs"]);
}

/// Run a suite of reference-parity cases from one fixture. Same per-case
/// semantics as runParityFixture; lets a single fixture/test cover a whole
/// matrix (e.g. element mode × selection pattern). Schema:
///   {
///     "name": "...", "tolerance": 1e-4,
///     "cases": [ { "name": "...", "input": [...], "op": [...],
///                  "expected_pairs": [ {before, after}, ... ] }, ... ]
///   }
/// A per-case `tolerance` overrides the suite default.
void runParitySuite(string fixtureJson) {
    auto fx       = parseJSON(fixtureJson);
    string suite  = ("name" in fx) ? fx["name"].str : "<unnamed-suite>";
    double tolDef = ("tolerance" in fx) ? asDouble(fx["tolerance"]) : 1e-3;
    foreach (cs; fx["cases"].array) {
        string cn  = suite ~ "/" ~ (("name" in cs) ? cs["name"].str : "<case>");
        double tol = ("tolerance" in cs) ? asDouble(cs["tolerance"]) : tolDef;
        runOneParity(cn, tol, cs["input"], cs["op"], cs["expected_pairs"]);
    }
}

// One parity case: run `input` steps, snapshot vibe3d's pre-op verts, resolve
// each to a reference `before`/`after` pair by position, run `op` steps, then
// assert every vertex landed on its reference `after` within tolerance.
private void runOneParity(string name, double tol,
                          JSONValue input, JSONValue op, JSONValue expectedPairs) {
    double matchTol2 = tol * tol;  // matching uses the same radius as the assert

    foreach (i, step; input.array)
        runStep(step, name, "input", i);

    // Snapshot vibe3d's pre-op vertices (selection doesn't move geometry).
    auto preV  = readVertices();
    auto pairs = expectedPairs.array;
    // vibe3d's vertex count may EXCEED the reference's: a segmented box leaves
    // coincident un-welded duplicates at seams (same position, separate verts).
    // We match by position (many vibe3d verts → one reference pair), so only
    // require vibe3d has at least as many verts as reference pairs.
    assert(preV.length >= pairs.length,
        format("%s: vibe3d vertex count %d < reference pair count %d",
               name, preV.length, pairs.length));

    // For each vibe3d vertex, find the reference pair whose `before` matches
    // its pre-op position; that pair's `after` is the golden for this vertex.
    auto expected = new double[3][](preV.length);
    foreach (j, pv; preV) {
        ptrdiff_t hit = -1;
        foreach (k, pr; pairs) {
            auto b = pr["before"].array;
            double[3] bb = [asDouble(b[0]), asDouble(b[1]), asDouble(b[2])];
            if (dist2(pv, bb) <= matchTol2) { hit = k; break; }
        }
        assert(hit >= 0,
            format("%s: vibe3d pre-op vertex %d at [%.4f,%.4f,%.4f] has no "
                   ~ "matching reference `before` (primitive mismatch?)",
                   name, j, pv[0], pv[1], pv[2]));
        auto a = pairs[hit]["after"].array;
        expected[j] = [asDouble(a[0]), asDouble(a[1]), asDouble(a[2])];
    }

    foreach (i, step; op.array)
        runStep(step, name, "op", i);

    auto postV = readVertices();
    assert(postV.length == preV.length,
        format("%s: op changed vertex count %d -> %d (parity fixtures assume "
               ~ "topology-preserving ops)", name, preV.length, postV.length));

    foreach (j; 0 .. postV.length) {
        foreach (c; 0 .. 3)
            assert(fabs(postV[j][c] - expected[j][c]) <= tol,
                format("%s: v%d[%d] reference=%.6f vibe3d=%.6f (tol %.1e)",
                       name, j, c, expected[j][c], postV[j][c], tol));
    }
}
