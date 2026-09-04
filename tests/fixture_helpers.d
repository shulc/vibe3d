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
// The shared HTTP client resolves VIBE3D_TEST_PORT at runtime, so every
// parallel worker talks only to the instance assigned by run_test.d.

import http_client : testBaseUrl;
import std.json;
import std.net.curl : get, post;
import std.conv : to;
import std.math : fabs, PI, sqrt, acos;
import std.format : format;
import std.algorithm : sort;
import http_command_helpers : commandBody;

alias BASE = testBaseUrl;

private string endpointPath(string ep) {
    switch (ep) {
        case "reset":     return BASE ~ "/api/reset";
        case "select":    return BASE ~ "/api/command";
        case "command":   return BASE ~ "/api/command";
        case "transform": return BASE ~ "/api/command";
        case "script":    return BASE ~ "/api/script";
        case "load-mesh": return BASE ~ "/api/command";
        // POST /api/camera (topology-pen P0 fixtures need explicit camera
        // placement — azimuth/elevation/distance/focus — to pin a
        // background-surface raycast's world hit point precisely).
        case "camera":    return BASE ~ "/api/camera";
        default: assert(false, "fixture: unknown setup endpoint '" ~ ep ~ "'");
    }
}

// JSON numbers may parse as integer, uinteger, or float_ depending on how
// the literal was written ("0" vs "0.0"). Coerce uniformly so a golden of
// [0, 0, 0] compares the same as [0.0, 0.0, 0.0].
// Not `private`: reused by tests/stage_helpers.d (task 0342) so the
// stage-conformance suites share the exact same JSON-number coercion
// instead of a second copy drifting out of sync.
double asDouble(JSONValue v) {
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
// Mutating endpoints answer {"status":"ok"|"error"}; "error" aborts, UNLESS
// the step carries `"allowError": true` — an escape hatch (task 0395) for a
// captured case whose op is a DELIBERATE no-op at the command layer (e.g. a
// headless tool's applyHeadless() legitimately returning false because there
// is genuinely nothing to do — commands.mesh.bridge's/mesh.bridgeTool's
// single-open-chain case — which the /api/command bridge reports as
// `{"status":"error","message":"command '...' did not apply"}`, same as any
// other rejected command). Default (absent/false) preserves every existing
// fixture's strict behavior byte-for-byte.
private void postStep(JSONValue step, string name, string phase, size_t i) {
    string ep = step["endpoint"].str;
    string body = ("argstring" in step) ? step["argstring"].str
                : ("body"      in step) ? step["body"].toString
                : "";
    if (ep == "select")
        body = commandBody("mesh.select", body);
    else if (ep == "transform")
        body = commandBody("mesh.transform", body);
    else if (ep == "load-mesh")
        body = commandBody("scene.loadMesh", body);
    bool allowError = ("allowError" in step) && step["allowError"].type == JSONType.true_;
    auto resp = cast(string) post(endpointPath(ep), body);
    if (resp.length && resp[0] == '{') {
        auto j = parseJSON(resp);
        if (!allowError && "status" in j && j["status"].str == "error")
            assert(false, format("%s: %s step %d (%s) failed: %s",
                                 name, phase, i, ep, resp));
        // Optional `expectStatus` (task 1150): assert the exact answer, not
        // merely "not an error". A fixture whose whole content is that our
        // command REFUSES has nothing to fail on otherwise — deleting the op
        // outright leaves the same mesh a refused op leaves, so without this
        // the case cannot tell the two apart.
        if ("expectStatus" in step) {
            string want = step["expectStatus"].str;
            string got  = ("status" in j) ? j["status"].str : "<none>";
            assert(got == want,
                format("%s: %s step %d (%s) answered %s, the fixture expects "
                       ~ "%s: %s", name, phase, i, ep, got, want, resp));
        }
        // Optional `expectMessageContains`: a refusal answers `error`, and so
        // does an unknown command id — but they are not the same event, and on
        // a fixture whose whole content is "our command RUNS and declines" the
        // difference is the content. Pinning the substring makes the case
        // reject a swapped-in command that merely also fails.
        if ("expectMessageContains" in step) {
            string need = step["expectMessageContains"].str;
            string msg  = ("message" in j) ? j["message"].str : "";
            import std.algorithm : canFind;
            assert(msg.canFind(need),
                format("%s: %s step %d (%s) answered %s, which does not "
                       ~ "contain %s", name, phase, i, ep, resp, need));
        }
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
// Not `private` — reused by tests/stage_helpers.d (task 0342).
double[3] jvec3(JSONValue v) {
    auto c = v.array; return [asDouble(c[0]), asDouble(c[1]), asDouble(c[2])];
}

// POST an argstring to /api/command; assert {"status":"ok"}.
// Not `private` — reused by tests/stage_helpers.d (task 0342) to drive
// `pipe_setup` commands (actr.<mode>, tool.pipe.attr falloff ...) without a
// second HTTP-driving copy.
void cmd(string argstring, string ctx) {
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

// Resolve POLYGON centroid-specs to face indices against the current
// /api/model. `coords` (above) keys a face on its FULL vertex ring, which a
// fixture can only spell for a face that exists in its own frozen base mesh;
// a multi-step case selects faces that only come into existence mid-case (the
// hexagon a merge leaves behind, the halves a split leaves behind), and their
// rings are not in the fixture. A centroid is spellable for those: it is a
// single point the case author already knows, and it is resolved against the
// LIVE mesh at the moment the step runs. Match radius is deliberately looser
// than COORD_EPS (a centroid is an average of n coordinates, so it carries n
// times the rounding of one), and an AMBIGUOUS key — two faces whose centroids
// both match — fails loudly rather than silently taking the first: two
// coincident faces is exactly what a paste-on-top-of-itself case produces.
private enum double CENTROID_EPS = 1e-3;
private int[] resolveCentroids(JSONValue centroidsArr, string ctx) {
    auto model = parseJSON(cast(string) get(BASE ~ "/api/model"));
    auto V = model["vertices"].array;
    auto F = model["faces"].array;
    double[3] centroidOf(size_t fi) {
        auto fv = F[fi].array;
        double[3] c = [0, 0, 0];
        foreach (ij; fv) {
            auto p = jvec3(V[cast(size_t) ij.integer]);
            c[0] += p[0]; c[1] += p[1]; c[2] += p[2];
        }
        double n = cast(double) fv.length;
        if (n > 0) { c[0] /= n; c[1] /= n; c[2] /= n; }
        return c;
    }
    int[] outIdx;
    foreach (spec; centroidsArr.array) {
        double[3] t = jvec3(spec);
        int hit = -1;
        int hits = 0;
        foreach (fi; 0 .. F.length) {
            if (dist2(centroidOf(fi), t) <= CENTROID_EPS * CENTROID_EPS) {
                if (hit < 0) hit = cast(int) fi;
                ++hits;
            }
        }
        assert(hit >= 0,
            format("%s: no polygon whose centroid is [%.4f,%.4f,%.4f]",
                   ctx, t[0], t[1], t[2]));
        assert(hits == 1,
            format("%s: centroid [%.4f,%.4f,%.4f] matches %d polygons - "
                   ~ "ambiguous key, the case must name the face another way",
                   ctx, t[0], t[1], t[2], hits));
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
// Not `private` — reused by tests/stage_helpers.d (task 0342) to run a
// fixture's `mesh_build` steps through the SAME step vocabulary (reset /
// select / translate / ...) instead of re-deriving mesh setup logic.
void runStep(JSONValue step, string name, string phase, size_t i) {
    string ctx = format("%s: %s step %d", name, phase, i);
    if ("reset" in step) {
        // {"reset":true} → default cube; {"reset":true,"empty":true} → empty
        // scene (use before prim.cube so the built primitive is the ONLY
        // geometry — otherwise prim.cube APPENDS onto the reset cube and the
        // two coincide at shared corners, doubling those verts).
        bool empty = ("empty" in step) && step["empty"].type == JSONType.true_;
        post(BASE ~ "/api/reset" ~ (empty ? "?empty=true" : ""), "");
    } else if ("select" in step) {
        auto sel    = step["select"];
        string mode = sel["mode"].str;
        int[] idx   = ("coords"    in sel) ? resolveCoords(mode, sel["coords"], ctx)
                    : ("centroids" in sel) ? resolveCentroids(sel["centroids"], ctx)
                    : [];
        string idxJson = "[";
        foreach (k, v; idx) { if (k) idxJson ~= ","; idxJson ~= format("%d", v); }
        idxJson ~= "]";
        auto resp = cast(string) post(BASE ~ "/api/command",
            commandBody("mesh.select",
                format(`{"mode":"%s","indices":%s}`, mode, idxJson)));
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
        auto resp = cast(string) post(BASE ~ "/api/command",
            commandBody("mesh.transform",
                format(`{"kind":"rotate","axis":[%.10g,%.10g,%.10g],"angle":%.10g,`
                       ~ `"pivot":[%.10g,%.10g,%.10g]}`,
                       ax[0], ax[1], ax[2], rad, pv[0], pv[1], pv[2])));
        auto j = parseJSON(resp);
        if ("status" !in j || j["status"].str != "ok")
            assert(false, format("%s: rotate_about failed: %s", ctx, resp));
    } else if ("scale_about" in step) {
        // Scale the selection by per-axis factors about an EXPLICIT pivot, via
        // the /api/transform primitive. Used by scale-parity fixtures: the
        // the captured headless scale operation pivots at the world origin, so
        // the fixtures pass pivot [0,0,0] — an engine-agnostic scale (no gizmo /
        // action-center policy involved, no recovery needed).
        auto s = step["scale_about"];
        auto fac = jvec3(s["factor"]);
        auto pv = jvec3(s["pivot"]);
        auto resp = cast(string) post(BASE ~ "/api/command",
            commandBody("mesh.transform",
                format(`{"kind":"scale","factor":[%.10g,%.10g,%.10g],`
                       ~ `"pivot":[%.10g,%.10g,%.10g]}`,
                       fac[0], fac[1], fac[2], pv[0], pv[1], pv[2])));
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
        } else if (fo["type"].str == "cylinder") {
            // Cylinder falloff: radial-perpendicular-to-axis. The weight
            // attenuates with distance to the AXIS line, so the axis MUST be
            // sent — omitting it lets the stage default (+Y) win, which would
            // measure perpendicular distance about the wrong axis and produce
            // the wrong per-vertex weights. `center` is NOT used by cylinder.
            auto s = jvec3(fo["size"]);
            auto ax = ("axis" in fo) ? jvec3(fo["axis"]) : [0.0, 1.0, 0.0];
            cmd(format(`tool.pipe.attr falloff size "%g,%g,%g"`,
                       s[0], s[1], s[2]), ctx);
            cmd(format(`tool.pipe.attr falloff axis "%g,%g,%g"`,
                       ax[0], ax[1], ax[2]), ctx);
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
    } else if ("falloff_rotate_matrix" in step) {
        // MS-4.3 production-fold parity: drive a MULTI-AXIS rotation under a
        // falloff through the LIVE rotate tool (RX/RY/RZ Euler + the recovered
        // falloff handles, about the default action center = origin). vibe3d's
        // applyTRS now COMPOSES the three axes into one matrix blended once per
        // vertex (the fold), so it must land on the frozen reference `after`.
        // The stored `rotation`/`pivot` are the ground-truth matrix + origin; the
        // tool path rebuilds R from `euler_deg` (R = Rz·Ry·Rx, same as the fold).
        auto ft  = step["falloff_rotate_matrix"];
        auto eul = ft["euler_deg"];
        auto fo  = ft["falloff"];
        cmd("tool.set rotate on", ctx);
        cmd(format("tool.pipe.attr falloff type %s", fo["type"].str), ctx);
        cmd(format("tool.pipe.attr falloff shape %s",
                   ("shape" in fo) ? fo["shape"].str : "linear"), ctx);
        auto a = jvec3(fo["start"]);
        auto b = jvec3(fo["end"]);
        cmd(format(`tool.pipe.attr falloff start "%g,%g,%g"`, a[0], a[1], a[2]), ctx);
        cmd(format(`tool.pipe.attr falloff end "%g,%g,%g"`,   b[0], b[1], b[2]), ctx);
        cmd(format("tool.attr rotate RX %g", asDouble(eul["rx"])), ctx);
        cmd(format("tool.attr rotate RY %g", asDouble(eul["ry"])), ctx);
        cmd(format("tool.attr rotate RZ %g", asDouble(eul["rz"])), ctx);
        cmd("tool.doApply", ctx);
        cmd("tool.set rotate off", ctx);
    } else if ("element_transform" in step) {
        // Element-falloff translate via the LIVE xfrm.elementMove preset —
        // mirrors a reference-engine element-move pick+drag. The falloff
        // attenuates by distance to the picked element's GEOMETRY (vert /
        // segment / face), defined by `anchor` (the picked element's vertex
        // coords; resolved to anchorRing indices). `center` is the fallback
        // sphere centre used only when no `anchor` is given (single-point pick).
        // `translate` is the full (w=1) displacement the picked element
        // received — applied unscaled, so the per-vert weight reproduces the
        // reference verts. Multi-axis (the free screen-plane drag is live TXYZ).
        auto ft  = step["element_transform"];
        string tl = ("tool" in ft) ? ft["tool"].str : "xfrm.elementMove";
        auto fo  = ft["falloff"];
        auto tr  = jvec3(ft["translate"]);
        cmd(format("tool.set %s on", tl), ctx);
        cmd("tool.pipe.attr falloff type element", ctx);
        cmd(format("tool.pipe.attr falloff shape %s",
                   ("shape" in fo) ? fo["shape"].str : "linear"), ctx);
        cmd(format("tool.pipe.attr falloff dist %g", asDouble(fo["dist"])), ctx);
        // Connected Elements gate (ignore/useConnectivity/rigid/edgeLoops). For
        // edgeLoops the `anchor` is the picked EDGE's 2 verts; the stage walks
        // the edge loop into the full ring.
        if ("connect" in fo)
            cmd(format("tool.pipe.attr falloff connect %s", fo["connect"].str), ctx);
        if ("anchor" in fo) {
            // Picked element verts (engine-neutral coords) → anchorRing indices.
            int[] aidx = resolveCoords("vertices", fo["anchor"], ctx);
            string s = "";
            foreach (k, vi; aidx) { if (k) s ~= ","; s ~= format("%d", vi); }
            cmd(format(`tool.pipe.attr falloff anchorRing "%s"`, s), ctx);
        }
        if ("center" in fo) {
            auto cen = jvec3(fo["center"]);
            cmd(format("tool.pipe.attr actionCenter userPlacedX %g", cen[0]), ctx);
            cmd(format("tool.pipe.attr actionCenter userPlacedY %g", cen[1]), ctx);
            cmd(format("tool.pipe.attr actionCenter userPlacedZ %g", cen[2]), ctx);
        }
        cmd(format("tool.attr %s TX %g", tl, tr[0]), ctx);
        cmd(format("tool.attr %s TY %g", tl, tr[1]), ctx);
        cmd(format("tool.attr %s TZ %g", tl, tr[2]), ctx);
        cmd("tool.doApply", ctx);
        cmd(format("tool.set %s off", tl), ctx);
    } else if ("acen_transform" in step) {
        // Action-center transform: set an actr.<mode> preset (ACEN+AXIS), then
        // run a single-axis numeric transform. With actr.local on a multi-
        // cluster selection each cluster transforms about its own center along
        // its own local frame. attr is one of T/R/S {X,Y,Z}; the axis letter
        // selects the per-cluster frame index (X→right, Y→up, Z→fwd).
        auto ft = step["acen_transform"];
        string tl = ft["tool"].str;          // move|rotate|scale
        string at = ft["attr"].str;          // TX..SZ
        double vv = asDouble(ft["value"]);
        string ac = ft["acen"].str;          // local|origin|auto|...
        cmd(format("actr.%s", ac), ctx);
        cmd(format("tool.set %s on", tl), ctx);
        // Optional falloff (MS-4 per-cluster fold parity): a graded falloff makes
        // the per-cluster transform per-vertex weighted. Set the stage before the
        // attr, like falloff_transform.
        if ("falloff" in ft) {
            auto fo = ft["falloff"];
            cmd(format("tool.pipe.attr falloff type %s", fo["type"].str), ctx);
            cmd(format("tool.pipe.attr falloff shape %s",
                       ("shape" in fo) ? fo["shape"].str : "linear"), ctx);
            auto a = jvec3(fo["start"]);
            auto b = jvec3(fo["end"]);
            cmd(format(`tool.pipe.attr falloff start "%g,%g,%g"`, a[0], a[1], a[2]), ctx);
            cmd(format(`tool.pipe.attr falloff end "%g,%g,%g"`,   b[0], b[1], b[2]), ctx);
        }
        cmd(format("tool.attr %s %s %g", tl, at, vv), ctx);
        cmd("tool.doApply", ctx);
        cmd(format("tool.set %s off", tl), ctx);
    } else if ("loop_slice" in step) {
        // Loop Slice tool (topology op — adds verts/edges/faces). Activates on
        // the CURRENT edge selection (set by a prior {"select":{"mode":"edges",
        // ...}} step), places the slices, and commits via tool.doApply.
        //   { "loop_slice": { "positions": [t0, t1, ...] } }   // Free mode
        //   { "loop_slice": { "count": N, "mode": "uniform" } } // N uniform slices
        // `positions` lays the first slice via `position` and any extras via
        // `insertAt` (each `insertAt` grows Count and makes the new slice
        // Current); `count` lays N evenly-spaced slices under the given Mode.
        auto ls = step["loop_slice"];
        cmd("tool.set mesh.loopSliceTool on", ctx);
        // Optional Slice Selected (task 0248): restrict the cut to the selected
        // face region instead of the whole ring. `{ "loop_slice": { ...,
        // "select": true } }`.
        if ("select" in ls && ls["select"].type == JSONType.true_)
            cmd("tool.attr mesh.loopSliceTool select 1", ctx);
        // Optional Keep Quads (task 0249; watertight-by-default 0265): now a
        // geometric NO-OP — where the quad ring terminates at a non-quad face,
        // that neighbour absorbs the terminating midpoint (n-gon) so the cut stays
        // watertight + all-quad BY DEFAULT. `quad` is retained for panel parity
        // only. `{ "loop_slice": { ..., "quad": true } }`.
        if ("quad" in ls && ls["quad"].type == JSONType.true_)
            cmd("tool.attr mesh.loopSliceTool quad 1", ctx);
        // Optional Slice N-gon (task 0250): let the ring continue THROUGH a
        // non-quad face with >4 sides (it is sliced by the entry→exit chord)
        // instead of terminating at it. `{ "loop_slice": { ..., "ngon": true } }`.
        if ("ngon" in ls && ls["ngon"].type == JSONType.true_)
            cmd("tool.attr mesh.loopSliceTool ngon 1", ctx);
        // Optional Split (task 0251): duplicate the loop's rail midpoints so the
        // single connected loop becomes two disconnected boundary edge-loops.
        // `{ "loop_slice": { ..., "split": true } }`.
        if ("split" in ls && ls["split"].type == JSONType.true_)
            cmd("tool.attr mesh.loopSliceTool split 1", ctx);
        // Optional Cap Sections (task 0252): with Split on, close each opened
        // section by bridging its lo/hi boundary loops with a strip of cap quads
        // (a closed ring caps to boundary-edge count 0). Default is ON in the tool,
        // so this is only sent when the key is PRESENT (true → 1, false → 0) to let
        // a fixture pin either state. `{ "loop_slice": { ..., "caps": false } }`.
        if ("caps" in ls)
            cmd(format("tool.attr mesh.loopSliceTool caps %d",
                       ls["caps"].type == JSONType.true_ ? 1 : 0), ctx);
        // Optional Gap (task 0253): with Split on, push the two split boundary
        // loops apart by this width (±gap/2 along the cut direction) so any cap
        // quads gain real area. `{ "loop_slice": { ..., "split": true, "gap": G } }`.
        if ("gap" in ls)
            cmd(format("tool.attr mesh.loopSliceTool gap %g", asDouble(ls["gap"])), ctx);
        // Optional Preserve Curvature (task 0254): place the new loop verts on a
        // Catmull-Rom spline through the rail's cage neighbours (bulging to follow
        // a curved cage) instead of the straight chord. `{ "loop_slice": { ...,
        // "curvature": true } }`.
        if ("curvature" in ls && ls["curvature"].type == JSONType.true_)
            cmd("tool.attr mesh.loopSliceTool curvature 1", ctx);
        // Optional Tension (task 0255): strength of Preserve Curvature — a fraction
        // (UI percent) scaling the spline bulge (1.0 = full, 0.0 = flat chord,
        // unbounded). Only meaningful with `curvature` on. `{ "loop_slice": { ...,
        // "curvature": true, "tension": 0.5 } }`.
        if ("tension" in ls)
            cmd(format("tool.attr mesh.loopSliceTool tension %g", asDouble(ls["tension"])), ctx);
        // Optional 1D profile cutter (task 0256): `profile` names a built-in profile
        // curve (flat/round/vee/step) whose along-cut samples REPLACE the placement,
        // and `depth` is the Inset (normal displacement scale). A non-flat profile
        // presses its cross-section into each slice. `{ "loop_slice": { ...,
        // "profile": "vee", "depth": 2.0 } }`.
        if ("profile" in ls)
            cmd(format("tool.attr mesh.loopSliceTool profile %s", ls["profile"].str), ctx);
        if ("depth" in ls)
            cmd(format("tool.attr mesh.loopSliceTool depth %g", asDouble(ls["depth"])), ctx);
        // Optional Reverse Direction (task 0257): mirror the 1D profile along the
        // cut (t → 1-t, re-sorted), so an asymmetric profile (e.g. Step) cuts in
        // the mirrored orientation. `{ "loop_slice": { ..., "profile": "step",
        // "depth": 2.0, "reversex": true } }`.
        if ("reversex" in ls && ls["reversex"].type == JSONType.true_)
            cmd("tool.attr mesh.loopSliceTool reversex 1", ctx);
        // Optional Reverse Inset (task 0258): flip the profile's inset/displacement
        // sign (h → -h), so the profile presses OUT of the surface instead of into
        // it. `{ "loop_slice": { ..., "profile": "vee", "depth": 2.0,
        // "reversey": true } }`.
        if ("reversey" in ls && ls["reversey"].type == JSONType.true_)
            cmd("tool.attr mesh.loopSliceTool reversey 1", ctx);
        // Optional Keep Aspect (task 0259): auto-derive the Inset from the cut's
        // world span so the normalized profile keeps its aspect ratio, instead of
        // the manual depth. `{ "loop_slice": { ..., "profile": "vee", "aspect":
        // true } }`.
        if ("aspect" in ls && ls["aspect"].type == JSONType.true_)
            cmd("tool.attr mesh.loopSliceTool aspect 1", ctx);
        if ("positions" in ls) {
            cmd("tool.attr mesh.loopSliceTool mode free", ctx);
            auto ps = ls["positions"].array;
            cmd(format("tool.attr mesh.loopSliceTool position %g", asDouble(ps[0])), ctx);
            foreach (k; 1 .. ps.length)
                cmd(format("tool.attr mesh.loopSliceTool insertAt %g", asDouble(ps[k])), ctx);
        } else {
            if ("mode" in ls)
                cmd(format("tool.attr mesh.loopSliceTool mode %s", ls["mode"].str), ctx);
            long cnt = ("count" in ls) ? ls["count"].integer : 1;
            cmd(format("tool.attr mesh.loopSliceTool count %d", cnt), ctx);
        }
        cmd("tool.doApply", ctx);
        cmd("tool.set mesh.loopSliceTool off", ctx);
    } else if ("slice" in step) {
        // Slice tool (mesh.sliceTool, task 0266 S0) — a plane/line cut whose
        // plane passes through the Start→End line PERPENDICULAR to the work
        // plane (headless work-plane normal = default world XZ ⇒ +Y). Topology
        // op (adds crossing verts / chord-splits faces via mesh_ops.cut.cutByPlane).
        //   { "slice": { "start": [x,y,z], "end": [x,y,z] } }
        // Optional `"fast": true/false` sets the S1 preview gate before the
        // commit. The committed geometry is fast-independent (the headless
        // commit is a single cut either way), so a fixture can pin both.
        //   { "slice": { "start": [...], "end": [...], "fast": true } }
        auto sl = step["slice"];
        auto s  = jvec3(sl["start"]);
        auto en = jvec3(sl["end"]);
        cmd("tool.set mesh.sliceTool on", ctx);
        if ("fast" in sl)
            cmd(format("tool.attr mesh.sliceTool fast %d",
                       sl["fast"].type == JSONType.true_ ? 1 : 0), ctx);
        // Optional `"infinite": true/false` (S4): OFF (default) clips the cut to
        // the drawn Start→End span; ON slices the whole mesh (the S0 behavior).
        if ("infinite" in sl)
            cmd(format("tool.attr mesh.sliceTool infinite %d",
                       sl["infinite"].type == JSONType.true_ ? 1 : 0), ctx);
        // Optional `"split": true/false` (S7): OFF (default) is the connected
        // single cut; ON duplicates the plane-cut loop into two disconnected
        // boundary loops (the surface splits into two sections along the cut).
        if ("split" in sl)
            cmd(format("tool.attr mesh.sliceTool split %d",
                       sl["split"].type == JSONType.true_ ? 1 : 0), ctx);
        // Optional `"caps": true/false` (S8): with Split on, seal each split
        // section's boundary loop with a cap polygon (default ON; no-op while
        // Split off). A fixture can pin either state.
        if ("caps" in sl)
            cmd(format("tool.attr mesh.sliceTool caps %d",
                       sl["caps"].type == JSONType.true_ ? 1 : 0), ctx);
        // Optional Gap / Offset Side (S9, task 0275): with Split on, push the two
        // split boundary loops apart by `gap` along the cut-plane normal, offset
        // by `gapSide` (center/positive/negative). Default gap 0 (coincident) —
        // unset leaves the S7/S8 result byte-for-byte.
        if ("gap" in sl)
            cmd(format("tool.attr mesh.sliceTool gap %g", asDouble(sl["gap"])), ctx);
        if ("gapSide" in sl)
            cmd(format("tool.attr mesh.sliceTool gapSide %s", sl["gapSide"].str), ctx);
        // Optional Angle Snap (S5): `"snap": true` quantizes the line's
        // work-plane angle to the nearest `"snapAngle"` (degrees, default 45)
        // multiple before the plane is built. Default OFF, so unset = the raw
        // line (every pre-S5 golden stays green).
        if ("snap" in sl)
            cmd(format("tool.attr mesh.sliceTool snap %d",
                       sl["snap"].type == JSONType.true_ ? 1 : 0), ctx);
        if ("snapAngle" in sl)
            cmd(format("tool.attr mesh.sliceTool snapAngle %g",
                       asDouble(sl["snapAngle"])), ctx);
        cmd(format("tool.attr mesh.sliceTool startX %g", s[0]), ctx);
        cmd(format("tool.attr mesh.sliceTool startY %g", s[1]), ctx);
        cmd(format("tool.attr mesh.sliceTool startZ %g", s[2]), ctx);
        cmd(format("tool.attr mesh.sliceTool endX %g", en[0]), ctx);
        cmd(format("tool.attr mesh.sliceTool endY %g", en[1]), ctx);
        cmd(format("tool.attr mesh.sliceTool endZ %g", en[2]), ctx);
        // Optional axis OVERRIDE (S3; owner-revised 0284): `"axis": "x|y|z|custom"`
        // LOCKS the cut-plane normal to a world axis (x/y/z) or the custom
        // `"vector"` [x,y,z], independent of the drawn line. There is no "free"
        // value — OMITTING `axis` leaves the default drag plane (drawn line ⟂
        // work plane). `vector` is only consulted when axis == custom.
        if ("axis" in sl)
            cmd(format("tool.attr mesh.sliceTool axis %s", sl["axis"].str), ctx);
        if ("vector" in sl) {
            auto v = jvec3(sl["vector"]);
            cmd(format("tool.attr mesh.sliceTool vectorX %g", v[0]), ctx);
            cmd(format("tool.attr mesh.sliceTool vectorY %g", v[1]), ctx);
            cmd(format("tool.attr mesh.sliceTool vectorZ %g", v[2]), ctx);
        }
        cmd("tool.doApply", ctx);
        cmd("tool.set mesh.sliceTool off", ctx);
    } else if ("subdivide" in step) {
        // mesh.subdivide (task 0291: builds a dense curved regression mesh —
        // the Slice split+caps+gap sliver case only reproduces on subdivided
        // geometry). `times` repeats the command (default 1); `mode` selects
        // ccsds/flat/smooth (default ccsds, the command's own default — no
        // explicit mode is sent unless the fixture overrides it, so the
        // default argstring form `mesh.subdivide` is used).
        //   { "subdivide": { "times": 2 } }
        //   { "subdivide": { "times": 2, "mode": "flat" } }
        auto sd = step["subdivide"];
        long times = ("times" in sd) ? sd["times"].integer : 1;
        foreach (_; 0 .. times) {
            if ("mode" in sd)
                cmd(format("mesh.subdivide mode:%s", sd["mode"].str), ctx);
            else
                cmd("mesh.subdivide", ctx);
        }
    } else if ("poly_inset" in step) {
        // Polygon Inset (mesh.polyInsetTool, task 0359) — headless Post-Mode
        // apply of the interactive tool: tool.set on, tool.attr inset <v>,
        // tool.doApply, tool.set off. Mirrors the reference's own
        // panel-apply gesture (`tool.attr inset …` followed by `tool.doApply`).
        //   { "poly_inset": { "inset": 0.2 } }
        auto pi = step["poly_inset"];
        double v = asDouble(pi["inset"]);
        cmd("tool.set mesh.polyInsetTool on", ctx);
        cmd(format("tool.attr mesh.polyInsetTool inset %g", v), ctx);
        cmd("tool.doApply", ctx);
        cmd("tool.set mesh.polyInsetTool off", ctx);
    } else if ("smooth_shift" in step) {
        // Smooth Shift + Thicken (mesh.smoothShiftTool, task 0358). Drives
        // the interactive tool headlessly on the CURRENT polygon selection
        // (empty ⇒ whole mesh, matching the kernel's mask convention):
        // tool.set on, the 5 captured attrs via tool.attr, tool.doApply,
        // tool.set off. Unset attrs keep the tool's own captured defaults
        // (shift=0, scale=1, maxAngle=89.5deg, thicken=false, sharp=false —
        // `thicken`/`sharp` are both booleans; see tools/smooth_shift_tool.d).
        //   { "smooth_shift": { "shift": 0.3, "scale": 0.5, "thicken": true } }
        auto ss = step["smooth_shift"];
        cmd("tool.set mesh.smoothShiftTool on", ctx);
        if ("shift" in ss)
            cmd(format("tool.attr mesh.smoothShiftTool shift %g", asDouble(ss["shift"])), ctx);
        if ("scale" in ss)
            cmd(format("tool.attr mesh.smoothShiftTool scale %g", asDouble(ss["scale"])), ctx);
        if ("maxAngle" in ss)
            cmd(format("tool.attr mesh.smoothShiftTool maxAngle %g", asDouble(ss["maxAngle"])), ctx);
        if ("thicken" in ss)
            cmd(format("tool.attr mesh.smoothShiftTool thicken %d",
                       ss["thicken"].type == JSONType.true_ ? 1 : 0), ctx);
        if ("sharp" in ss)
            cmd(format("tool.attr mesh.smoothShiftTool sharp %d",
                       ss["sharp"].type == JSONType.true_ ? 1 : 0), ctx);
        cmd("tool.doApply", ctx);
        cmd("tool.set mesh.smoothShiftTool off", ctx);
    } else if ("endpoint" in step) {
        postStep(step, name, phase, i);
    } else {
        assert(false, format("%s: unrecognized step %s", ctx, step.toString));
    }
}

// ---------------------------------------------------------------------------
// THE `provenance` VOCABULARY — the ONE public-tree copy (task 3340, item C;
// backlog 3302).
//
// AUTHORITY vs COPIES. `tools/local/fixture_gen/provenance.py` (PRIVATE tree)
// is the authority: it is what stamps a block at generation time, so a value
// it does not know cannot be written by the generator at all. A public test
// lane must not shell out to a private script — that was task 1063's reason
// for a D-side copy, and it still holds. What did NOT hold was the NUMBER of
// copies. Measured 2026-08-29 there were THREE lists for one field:
//
//     tools/local/fixture_gen/provenance.py      METHOD_VALUES   11  authority
//     tests/unit/fixture_provenance_census_test.d kMethodValues  11  in step
//     this file (inside `requireProvenance`)                      8  THREE BEHIND
//
// and the third had been behind for ELEVEN DAYS, over five fixtures already
// carrying `static-read` / `gui-gesture` / `debug-live` (measured on the
// corpus: 3 / 1 / 1 of 191 `method` values). It was not red only because none
// of those five is read through `runFixture`. The first one that was would
// have reddened on a VALID value, advising `"unknown"` — erasing a measured
// distinction to satisfy a stale list.
//
// WHY THE FIX IS "ONE HAND-TYPED PUBLIC LIST", NOT "ONE SHARED D MODULE".
// A shared module was tried first and MEASURED to be unavailable, which is
// worth recording so nobody re-tries it blind:
//
//   * this file is compiled by `run_test.d`'s plain lane
//     (`dmd -unittest -J=tests -I=<scratch> -I=tests <helpers> <test>`), with
//     no `-i`, and it is COPIED into a per-worker scratch dir when the port is
//     rewritten — so it can neither link a module that is not on that command
//     line nor root anything on `__FILE_FULL_PATH__`;
//   * the census is compiled by `dub test --config=tests`, whose `sourcePaths`
//     are `source` + `tests/unit` and whose `importPaths` are `source` +
//     `tools/perf`. Adding `"tests"` to those `importPaths` — the obvious way
//     to let the census import a module under `tests/` — CHANGES THE MODULE
//     NAMES DUB DERIVES for every `tests/unit/**` file that declares no
//     `module` statement (most of them), and `dub test --config=tests` then
//     fails to build with `module `mesh_stats_test` … must be imported with
//     'import mesh_stats_test;'`. Measured on this branch.
//
// So the two lanes cannot share a compiled symbol without changing a build
// file for one of them. What they CAN share is this text: the census PARSES
// the two arrays below out of this file, and pins them by VALUE NAME to the
// private Python authority. Result: two hand-typed lists in the world (one
// public here, one private there), each named by the other's checker when
// they disagree — instead of three lists and no checker at all.
//
// ADDING A VALUE is therefore a two-file edit, deliberately: here, and in
// `tools/local/fixture_gen/provenance.py`. Doing one without the other reddens
// `tests/unit/fixture_provenance_census_test.d` naming the value and the side.
//
// The two array literals are parsed by that census — keep them as plain
// one-line-per-chunk string literals, and do not build either from another
// expression.
// ---------------------------------------------------------------------------

/// `provenance.source`. Mirrors `provenance.py`'s `SOURCE_VALUES`.
static immutable string[] kProvenanceSourceValues = [
    "live-capture", "simulated", "analytic", "unknown",
];

/// `provenance.method`. Mirrors `provenance.py`'s `METHOD_VALUES`.
///
/// The three task 3302 found missing here, and why none is interchangeable
/// with an incumbent:
///   static-read  (2026-08-28, task 2680) decoded from a static artefact, with
///                no process running at all;
///   gui-gesture  (2026-08-28, task 2920) a live pointer gesture in the
///                reference's own graphical interface — `capture-drag` no
///                longer denotes that;
///   debug-live   (2026-08-28, task 2920) read out of a live process under a
///                debugger.
/// Folding any of them into `unknown` to satisfy a short list is the exact
/// harm backlog 3302 was filed for.
static immutable string[] kProvenanceMethodValues = [
    "capture-drag", "command", "from-trace", "rr-memory", "self-drive",
    "closed-form", "hand", "static-read", "gui-gesture", "debug-live", "unknown",
];

/// task 0366: assert a golden fixture carries a `provenance` block before
/// the runner trusts it as a parity/smoke check. A bare (pre-0366, or a
/// hand-added fixture that forgot the block) fixture is a coding mistake,
/// not a valid state — this fails loud at the LIVE runner as the D-side
/// belt-and-suspenders backstop to tools/local/fixture_gen/provenance_check.py
/// (the offline Python gate, run separately in run_all.d's `provenance`
/// lane). Does not judge the block's CONTENT (see provenance.lint_provenance
/// for that, Python-side only) — only that one is present at all.
void requireProvenance(JSONValue fx, string name) {
    assert("provenance" in fx,
        format("%s: golden fixture has no 'provenance' block (task 0366 — "
               ~ "every golden must carry structured provenance; back-fill it "
               ~ "via tools/local/fixture_gen/backfill_provenance.py or stamp "
               ~ "it at generation time via provenance.make_provenance)", name));

    // Task 1063: check the block's CONTENT, not merely its presence.
    // Presence-only let seven fixtures reach the remote carrying a `method`
    // outside the vocabulary — three of them through review and both gate
    // lanes — because the offline Python checker that would have caught it is
    // in NEITHER lane, and this assertion, which IS in both, was not looking.
    //
    // THE LISTS MOVED TO MODULE SCOPE IN TASK 3340 and this function now reads
    // them from there — see `kProvenanceSourceValues` / `kProvenanceMethodValues`
    // above for why one field had THREE vocabularies and what pins them now.
    auto prov = fx["provenance"];
    alias kSources = kProvenanceSourceValues;
    alias kMethods = kProvenanceMethodValues;
    void requireOneOf(string field, const string[] allowed) {
        assert(field in prov,
            format("%s: provenance is missing '%s'", name, field));
        assert(prov[field].type == JSONType.string,
            format("%s: provenance.%s must be a string, got %s",
                   name, field, prov[field].toString));
        immutable v = prov[field].str;
        bool ok = false;
        foreach (a; allowed) if (v == a) { ok = true; break; }
        assert(ok, format(
            "%s: provenance.%s is %s, which is not one of %s. TWO different "
            ~ "faults land here and the fix is NOT the same:\n"
            ~ "  (a) the value is prose, or a guess. Prose belongs in 'notes'; "
            ~ "if the real value is genuinely unknown write \"unknown\" — "
            ~ "every vocabulary carries it deliberately. This is the mistake "
            ~ "task 1063 was filed for.\n"
            ~ "  (b) the value is a REAL, measured method this list has not "
            ~ "caught up with. Then \"unknown\" is the wrong answer: it "
            ~ "erases the distinction that was measured. Add the value to "
            ~ "kProvenanceMethodValues in tests/fixture_helpers.d AND to "
            ~ "tools/local/fixture_gen/provenance.py — the census "
            ~ "(tests/unit/fixture_provenance_census_test.d) pins those two to "
            ~ "each other by name. Backlog 3302 is this list having been three "
            ~ "values behind for eleven days.",
            name, field, prov[field].toString, allowed));
    }
    requireOneOf("source", kSources);
    requireOneOf("method", kMethods);
}

/// Run a frozen-state fixture given as its JSON text. Executes the setup
/// steps against a live vibe3d, then asserts /api/model's vertices match
/// `expected.vertices` within tolerance. Asserts (with a diagnostic) on
/// the first mismatch — count, per-vertex, or a failed setup step.
void runFixture(string fixtureJson) {
    auto fx     = parseJSON(fixtureJson);
    string name = ("name" in fx) ? fx["name"].str : "<unnamed>";
    requireProvenance(fx, name);
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
    requireProvenance(fx, name);
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
    requireProvenance(fx, suite);
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

// ===========================================================================
// Verifier shelf (tool-port pipeline Stage 2). A generated fixture declares a
// "verifier" (chosen by the captured gesture's effect_class) that names one of
// the runners below. `runParitySuite` above IS the `rigid-cluster` verifier
// (the transform family); the runners here cover the other effect classes:
//   topology-diff  — count deltas + per-vertex nearest-match (+ analytic lerp)
//   preview-state  — hover/transient parity read from /api/tool/state (0234)
//   attr-echo      — an attr edit echoes in tool state + its derived geometry
// All are engine-neutral: the golden is frozen in the fixture, no external
// reference tool runs at test time.
// ===========================================================================

// GET /api/model and return [vertexCount, edgeCount, faceCount].
private long[3] readCounts() {
    auto m = parseJSON(cast(string) get(BASE ~ "/api/model"));
    long ec = ("edgeCount" in m) ? m["edgeCount"].integer : -1;
    return [m["vertexCount"].integer, ec, m["faceCount"].integer];
}

private void assertCounts(string name, string phase, JSONValue exp, long[3] got) {
    if ("verts" in exp) assert(exp["verts"].integer == got[0],
        format("%s: %s vertex count expected %d, got %d",
               name, phase, exp["verts"].integer, got[0]));
    if ("edges" in exp && got[1] >= 0) assert(exp["edges"].integer == got[1],
        format("%s: %s edge count expected %d, got %d",
               name, phase, exp["edges"].integer, got[1]));
    if ("faces" in exp) assert(exp["faces"].integer == got[2],
        format("%s: %s face count expected %d, got %d",
               name, phase, exp["faces"].integer, got[2]));
}

// ---------------------------------------------------------------------------
// Coordinate-keyed STRUCTURE readers (task 1160).
//
// MERGE NOTE: `readFaceRings` and `ringEq` below are BYTE-IDENTICAL to the
// pair task 1140 adds to this same file for the divergence runner (and which
// task 1150 in turn adopted byte-identically). They arrived independently and
// from opposite directions -- 1140 needed a channel that could SEE a
// disagreement a vertex-and-count check calls parity, 1160 needed one that
// could CONFIRM an agreement the same check cannot. Whichever lands second:
// delete one of the two identical copies, keep either, and leave every call
// site alone. Nothing else here collides.
//
// The fixture KEY spellings differ on purpose and are not a third dialect:
// this runner's schema has always prefixed its frozen state `expected_*`
// (`expected_before`, `expected_after`, `expected_vertices`,
// `expected_face_degrees`), so the new channels follow ITS convention rather
// than the divergence runner's bare `faces` / `material_groups`. Same channel,
// same comparison, same helper -- the noun in front of it belongs to the
// runner it lives in.
//
// A count plus a set of vertex POSITIONS cannot see which vertices form which
// face, and that is precisely the question several frozen agreements are about
// ("which of the two faces containing both endpoints got cut", "does a paste
// share the original's vertices or duplicate them"). These read the face rings
// as COORDINATES so a fixture never names a vertex index -- index order is not
// a promise across engines, and a topology-changing op renumbers within one
// engine anyway.
// ---------------------------------------------------------------------------

// True iff some vibe3d vertex sits within `tol` of `p`.
private bool hasVertexNear(double[3][] verts, double[3] p, double tol) {
    double t2 = tol * tol;
    foreach (v; verts) if (dist2(v, p) <= t2) return true;
    return false;
}

// Approximate JSON equality: strings exact, bools by type, numbers within tol,
// arrays element-wise. Used to compare an `expected` state fragment against the
// live /api/tool/state.
private bool jApproxEq(JSONValue e, JSONValue a, double tol) {
    if (e.type == JSONType.array) {
        if (a.type != JSONType.array || e.array.length != a.array.length) return false;
        foreach (k; 0 .. e.array.length)
            if (!jApproxEq(e.array[k], a.array[k], tol)) return false;
        return true;
    }
    if (e.type == JSONType.string)
        return a.type == JSONType.string && e.str == a.str;
    if (e.type == JSONType.true_ || e.type == JSONType.false_)
        return e.type == a.type;
    return fabs(asDouble(e) - asDouble(a)) <= tol;   // numeric
}

/// `topology-diff` verifier. For each case: run `input` (reach the pre-op
/// mesh), optionally assert `expected_before` counts, run `op` (the topology-
/// changing gesture, e.g. loop_slice), then assert `expected_after` counts and
/// that vibe3d's post-op vertices match the frozen golden by BIDIRECTIONAL
/// nearest-match (a topology-changing op renumbers verts, so match by position
/// both ways rather than by index).
/// Optional `lerp_checks` add a reference-INDEPENDENT analytic assertion: each
/// new vertex must sit at lerp(a, b, t) of a pre-op edge (a Loop Slice cut lands
/// every new vertex on its rail at the slice parameter). Schema:
///   { "name": "...", "tolerance": 1e-4,
///     "cases": [ { "name": "...", "input": [...], "op": [...],
///                  "expected_before": {"verts":V,"edges":E,"faces":F},
///                  "expected_after":  {"verts":V,"edges":E,"faces":F},
///                  "expected_vertices": [[x,y,z], ...],
///                  "expected_face_degrees": [4,4,4,6,6,6,6],
///                  "lerp_checks": [ {"a":[..],"b":[..],"t":0.3,"point":[..]} ]
///                } ] }
/// Optional `expected_face_degrees` is a CONNECTIVITY-shape check
/// complementary to `expected_vertices`' position bijection: the
/// multiset of post-op face vertex-counts (any order — compared sorted),
/// e.g. `[4,4,6,6,6,6]` for a squared single-face bevel (1 inner quad +
/// 4 hexagon sides absorbing splits + ... — see poly.bevel's Q1-Q4 task
/// 0458 fixtures). Catches a wrong-shaped n-gon rewrite (e.g. accidentally
/// emitting 2 pentagons instead of 1 quad + 1 hexagon) that a bare vertex/
/// face COUNT plus a position bijection could miss.
///
/// Task 1160 adds three more optional, coordinate-keyed channels so a frozen
/// reference AGREEMENT can be pinned at the strength it was measured at:
///   "expected_faces"      [ [[x,y,z], ...], ... ]  every face as its ring of
///                         POSITIONS, matched rotation-invariantly but
///                         direction-SENSITIVELY, as a multiset. This is the
///                         channel that says WHICH vertices form which face --
///                         `expected_vertices` is only a position set and
///                         cannot see a re-wired ring, a duplicated face, or a
///                         flipped winding.
///   "expected_tag_groups" [ [i, j], [k] ]  the PARTITION of faces by material,
///                         as indices into `expected_faces`. Material VALUES
///                         are never compared (the reference names surfaces by
///                         string, we by index); which faces share one is.
/// Task 1310 makes the STRENGTH of `expected_faces` explicit and required:
///   "face_ring_start"      "compared" | "ignored"   (fixture-level, per-case
///                          override allowed). "compared" matches rings
///                          start-and-all; "ignored" keeps the historic
///                          rotation-tolerant match and MUST carry a
///                          "face_ring_start_note" saying why. A fixture that
///                          compares face rings and declares neither fails.
///
///   "expected_selection"  {"vertices":[[x,y,z],...],
///                          "polygons":[<centroid>,...],
///                          "edges":[[[x,y,z],[x,y,z]],...]}
///                         the post-op selection, keyed on coordinates. Present
///                         only where the capture agreed on the selection
///                         channel as well; a case that agreed on geometry only
///                         omits it and says so in its own description.
void runTopologyDiffSuite(string fixtureJson) {
    auto fx      = parseJSON(fixtureJson);
    string suite = ("name" in fx) ? fx["name"].str : "<topo-suite>";
    requireProvenance(fx, suite);
    double tolD  = ("tolerance" in fx) ? asDouble(fx["tolerance"]) : 1e-4;
    auto tally = RingStartTally(suite);
    scope (exit) ringStartSummary(tally);
    foreach (cs; fx["cases"].array) {
        string cn  = suite ~ "/" ~ (("name" in cs) ? cs["name"].str : "<case>");
        double tol = ("tolerance" in cs) ? asDouble(cs["tolerance"]) : tolD;

        foreach (i, step; cs["input"].array) runStep(step, cn, "input", i);
        if ("expected_before" in cs)
            assertCounts(cn, "before", cs["expected_before"], readCounts());
        // Base material, read BEFORE the op, for `expected_tag_changed` below.
        auto baseMats = ("expected_tag_changed" in cs) ? readFaceMaterials() : null;

        foreach (i, step; cs["op"].array) runStep(step, cn, "op", i);
        if ("expected_after" in cs)
            assertCounts(cn, "after", cs["expected_after"], readCounts());

        if ("expected_face_degrees" in cs) {
            auto model = parseJSON(cast(string) get(BASE ~ "/api/model"));
            long[] gotDeg;
            foreach (f; model["faces"].array) gotDeg ~= cast(long) f.array.length;
            gotDeg.sort();
            long[] wantDeg;
            foreach (w; cs["expected_face_degrees"].array) wantDeg ~= w.integer;
            wantDeg.sort();
            assert(gotDeg == wantDeg,
                format("%s: face-degree multiset expected %s, got %s",
                       cn, wantDeg, gotDeg));
        }

        auto got = readVertices();
        if ("expected_vertices" in cs) {
            auto want = cs["expected_vertices"].array;
            foreach (w; want) {
                double[3] wp = jvec3(w);
                assert(hasVertexNear(got, wp, tol),
                    format("%s: golden vertex [%.4f,%.4f,%.4f] has no vibe3d "
                           ~ "match (tol %.1e)", cn, wp[0], wp[1], wp[2], tol));
            }
            foreach (g; got) {
                bool found = false;
                foreach (w; want) if (dist2(g, jvec3(w)) <= tol*tol) { found = true; break; }
                assert(found,
                    format("%s: vibe3d vertex [%.4f,%.4f,%.4f] not in golden "
                           ~ "set (tol %.1e)", cn, g[0], g[1], g[2], tol));
            }
        }
        // ---- coordinate-keyed FACE RINGS (task 1160) --------------------
        // `expected_vertices` above is a position SET: it cannot see which
        // vertices form which face, cannot see a face duplicated on top of
        // itself, and cannot see a winding flip. `expected_faces` freezes the
        // rings themselves, matched rotation-invariantly but direction-
        // SENSITIVELY, as a MULTISET (so a paste that lands a second copy of a
        // face on the original is a different answer from one that does not).
        ptrdiff_t[] faceMap;   // expected face index -> live face index
        if ("expected_faces" in cs) {
            // Task 1310: WHICH reading of "the same ring" this case gets is a
            // declared property of the fixture, not a silent property of the
            // matcher. See `ringStartDeclOf`.
            auto rs   = ringStartDeclOf(fx, cs, cn);
            auto live = readFaceRings();
            auto want = cs["expected_faces"].array;
            assert(live.length == want.length,
                format("%s: face count %d != frozen face count %d",
                       cn, live.length, want.length));
            auto used = new bool[](live.length);
            faceMap = new ptrdiff_t[](want.length);
            double[3][][] wantAll;
            foreach (wi, w; want) {
                auto wr = new double[3][](w.array.length);
                foreach (k, c; w.array) wr[k] = jvec3(c);
                wantAll ~= wr;
                ptrdiff_t hit = -1;
                foreach (li, lr; live)
                    if (!used[li] && ringMatchBy(wr, lr, tol, rs.compared)) { hit = li; break; }
                if (hit < 0) {
                    string spelled = "[";
                    foreach (k, c; wr) {
                        if (k) spelled ~= " ";
                        spelled ~= format("(%.4f,%.4f,%.4f)", c[0], c[1], c[2]);
                    }
                    spelled ~= "]";
                    assert(false, format(
                        "%s: frozen face %d %s has no live face with the same "
                        ~ "ring%s and the same winding (tol %.1e)%s",
                        cn, wi, spelled,
                        rs.compared ? ", the same START vertex" : "", tol,
                        rs.compared
                            ? " -- this fixture declares \"" ~ RING_START_KEY
                              ~ "\": \"compared\", so a ring that matches only "
                              ~ "under rotation fails here on purpose"
                            : ""));
                }
                used[hit] = true;
                faceMap[wi] = hit;
            }
            ringStartAccrue(tally, rs, wantAll, live, tol);
        }

        // ---- material PARTITION (task 1160) -----------------------------
        // Which faces share a material, never WHICH material: the reference
        // names surfaces by string and we by index, so the values are not
        // comparable and are deliberately not compared. Groups are given as
        // indices into `expected_faces` (which resolves them to coordinates),
        // and both sides are canonicalised -- each group sorted, the groups
        // sorted -- so neither engine's face iteration order can enter.
        if ("expected_tag_groups" in cs) {
            assert("expected_faces" in cs,
                format("%s: expected_tag_groups needs expected_faces (its "
                       ~ "groups are indices into it)", cn));
            auto mats = readFaceMaterials();
            assert(mats.length == faceMap.length,
                format("%s: faceMaterial length %d != face count %d",
                       cn, mats.length, faceMap.length));
            // live partition, expressed in EXPECTED-face indices
            long[][long] byMat;
            foreach (wi, li; faceMap) byMat[mats[li]] ~= cast(long) wi;
            // Canonicalised as SORTED TEXT: each group's members sorted, then
            // the groups themselves sorted as strings. Neither engine's face
            // iteration order, and no material id, can reach the comparison.
            string[] gotGroups;
            foreach (k; byMat.keys) {
                auto g = byMat[k].dup;
                g.sort();
                gotGroups ~= format("%s", g);
            }
            string[] wantGroups;
            foreach (g; cs["expected_tag_groups"].array) {
                long[] one;
                foreach (v; g.array) one ~= v.integer;
                one.sort();
                wantGroups ~= format("%s", one);
            }
            gotGroups.sort();
            wantGroups.sort();
            assert(gotGroups == wantGroups,
                format("%s: material partition (by frozen face index) is %s, "
                       ~ "frozen partition is %s", cn, gotGroups, wantGroups));
        }

        // ---- which faces CHANGED their material (task 1160) --------------
        // A partition alone has a blind spot the sweep's own harness was caught
        // by: "every face changed to the same tag" and "no face changed at all"
        // are both ONE group, and the two are not the same answer. This channel
        // closes it. It compares a BOOLEAN per face -- "does this face's
        // material differ from the one the whole mesh started with" -- which is
        // comparable across the seam even though the tag VALUES are not.
        //
        // What it deliberately does NOT pin: WHICH of two competing tags a
        // merged face inherited. The two engines' tag values are private
        // namespaces, and the faces that carried them are gone by the time the
        // merge is dumped, so that law is not expressible from frozen data at
        // all. The capture settled it; this fixture pins the part that crosses.
        if ("expected_tag_changed" in cs) {
            assert(baseMats.length > 0,
                format("%s: expected_tag_changed needs a pre-op faceMaterial "
                       ~ "read, and the mesh had no faces", cn));
            immutable long baseTag = baseMats[0];
            foreach (m; baseMats)
                assert(m == baseTag, format(
                    "%s: the base mesh is not uniformly tagged, so 'differs "
                    ~ "from the base tag' is not defined for it", cn));
            auto mats2 = readFaceMaterials();
            long[] gotChanged;
            foreach (wi, li; faceMap) if (mats2[li] != baseTag) gotChanged ~= cast(long) wi;
            long[] wantChanged;
            foreach (v; cs["expected_tag_changed"].array) wantChanged ~= v.integer;
            gotChanged.sort();
            wantChanged.sort();
            assert(gotChanged == wantChanged, format(
                "%s: faces whose material differs from the base tag are %s, "
                ~ "frozen set is %s", cn, gotChanged, wantChanged));
        }

        // ---- post-op SELECTION (task 1160) ------------------------------
        // Present ONLY on cases whose capture agreed on the selection channel
        // too. A case that agreed on geometry but not on selection omits this
        // key and says so in its description -- the selection difference is a
        // recorded divergence, and folding it into a parity fixture would be
        // asserting a match that was never measured.
        if ("expected_selection" in cs) {
            auto es    = cs["expected_selection"];
            auto model = parseJSON(cast(string) get(BASE ~ "/api/model"));
            auto sel   = parseJSON(cast(string) get(BASE ~ "/api/selection"));
            auto V     = model["vertices"].array;
            auto E     = model["edges"].array;
            auto F     = model["faces"].array;
            double[3] vpos(long i) { return jvec3(V[cast(size_t) i]); }

            double[3][] gotV;
            foreach (ij; sel["selectedVertices"].array) gotV ~= vpos(ij.integer);
            double[3][] gotP;
            foreach (ij; sel["selectedFaces"].array) {
                auto fv = F[cast(size_t) ij.integer].array;
                double[3] c = [0, 0, 0];
                foreach (k; fv) { auto q = vpos(k.integer); c[0]+=q[0]; c[1]+=q[1]; c[2]+=q[2]; }
                double n = cast(double) fv.length;
                if (n > 0) { c[0]/=n; c[1]/=n; c[2]/=n; }
                gotP ~= c;
            }
            double[3][2][] gotE;
            foreach (ij; sel["selectedEdges"].array) {
                auto ee = E[cast(size_t) ij.integer].array;
                gotE ~= [vpos(ee[0].integer), vpos(ee[1].integer)];
            }

            void matchPoints(string label, double[3][] got, JSONValue want, double mtol) {
                assert(got.length == want.array.length, format(
                    "%s: selected %s count %d, frozen %d",
                    cn, label, got.length, want.array.length));
                auto used = new bool[](got.length);
                foreach (w; want.array) {
                    double[3] wp = jvec3(w);
                    bool found = false;
                    foreach (gi, g; got)
                        if (!used[gi] && dist2(g, wp) <= mtol * mtol) {
                            used[gi] = true; found = true; break;
                        }
                    assert(found, format(
                        "%s: frozen selected %s [%.4f,%.4f,%.4f] is not selected "
                        ~ "in vibe3d (tol %.1e)",
                        cn, label, wp[0], wp[1], wp[2], mtol));
                }
            }
            if ("vertices" in es) matchPoints("vertex", gotV, es["vertices"], tol);
            if ("polygons" in es) matchPoints("polygon centroid", gotP, es["polygons"], CENTROID_EPS);
            if ("edges" in es) {
                auto want = es["edges"].array;
                assert(gotE.length == want.length, format(
                    "%s: selected edge count %d, frozen %d",
                    cn, gotE.length, want.length));
                auto used = new bool[](gotE.length);
                foreach (w; want) {
                    auto pr = w.array;
                    double[3] a = jvec3(pr[0]), b = jvec3(pr[1]);
                    bool found = false;
                    foreach (gi, g; gotE) {
                        if (used[gi]) continue;
                        if ((dist2(g[0], a) <= tol*tol && dist2(g[1], b) <= tol*tol) ||
                            (dist2(g[0], b) <= tol*tol && dist2(g[1], a) <= tol*tol)) {
                            used[gi] = true; found = true; break;
                        }
                    }
                    assert(found, format(
                        "%s: frozen selected edge [%.4f,%.4f,%.4f]-[%.4f,%.4f,%.4f] "
                        ~ "is not selected in vibe3d", cn,
                        a[0], a[1], a[2], b[0], b[1], b[2]));
                }
            }
        }

        if ("lerp_checks" in cs) {
            foreach (lc; cs["lerp_checks"].array) {
                double[3] a = jvec3(lc["a"]), b = jvec3(lc["b"]);
                double t = asDouble(lc["t"]);
                double[3] p = [a[0]+(b[0]-a[0])*t, a[1]+(b[1]-a[1])*t, a[2]+(b[2]-a[2])*t];
                if ("point" in lc) {
                    double[3] pt = jvec3(lc["point"]);
                    assert(dist2(p, pt) <= tol*tol,
                        format("%s: lerp(a,b,%.4f)=[%.4f,%.4f,%.4f] != frozen "
                               ~ "point [%.4f,%.4f,%.4f]", cn, t,
                               p[0],p[1],p[2], pt[0],pt[1],pt[2]));
                }
                assert(hasVertexNear(got, p, tol),
                    format("%s: no vibe3d vertex at lerp(a,b,%.4f)="
                           ~ "[%.4f,%.4f,%.4f] (slice vert missing; tol %.1e)",
                           cn, t, p[0], p[1], p[2], tol));
            }
        }
    }
}

/// `preview-state` verifier. Runs `input` (which activates the tool, e.g.
/// selecting a seed edge + `tool.set`), then asserts the live /api/tool/state
/// (0234) matches the frozen `state_checks` fragment — hover/transient parity
/// by DATA, no screenshots. Schema:
///   { "name": "...", "tolerance": 1e-4,
///     "cases": [ { "name": "...", "input": [...],
///                  "state_checks": { "count": 1, "mode": "free",
///                                    "positions": [0.5] } } ] }
void runPreviewStateSuite(string fixtureJson) {
    auto fx      = parseJSON(fixtureJson);
    string suite = ("name" in fx) ? fx["name"].str : "<preview-suite>";
    requireProvenance(fx, suite);
    double tol   = ("tolerance" in fx) ? asDouble(fx["tolerance"]) : 1e-4;
    foreach (cs; fx["cases"].array) {
        string cn = suite ~ "/" ~ (("name" in cs) ? cs["name"].str : "<case>");
        foreach (i, step; cs["input"].array) runStep(step, cn, "input", i);
        auto st = parseJSON(cast(string) get(BASE ~ "/api/tool/state"));
        foreach (string key, exp; cs["state_checks"].object) {
            assert(key in st, format("%s: tool/state missing key '%s'", cn, key));
            assert(jApproxEq(exp, st[key], tol),
                format("%s: tool/state['%s'] expected %s, got %s",
                       cn, key, exp.toString, st[key].toString));
        }
    }
}

/// `attr-echo` verifier. Runs `input` (activate the tool), sets one attr, and
/// asserts it echoes back in /api/tool/state (`echo`) — then optionally commits
/// (`op`) and checks the attr's DERIVED geometry appears (`derived_vertices`,
/// nearest-match). Schema:
///   { "name": "...", "tolerance": 1e-4,
///     "cases": [ { "name": "...", "input": [...],
///                  "attr": { "tool": "mesh.loopSliceTool", "name": "position",
///                            "value": 0.3 },
///                  "echo": { "position": 0.3 },
///                  "op": [ {"loop_slice": {"positions":[0.3]}} ],
///                  "derived_vertices": [[x,y,z], ...] } ] }
void runAttrEchoSuite(string fixtureJson) {
    auto fx      = parseJSON(fixtureJson);
    string suite = ("name" in fx) ? fx["name"].str : "<attr-echo-suite>";
    requireProvenance(fx, suite);
    double tol   = ("tolerance" in fx) ? asDouble(fx["tolerance"]) : 1e-4;
    foreach (cs; fx["cases"].array) {
        string cn = suite ~ "/" ~ (("name" in cs) ? cs["name"].str : "<case>");
        foreach (i, step; cs["input"].array) runStep(step, cn, "input", i);

        auto at = cs["attr"];
        cmd(format("tool.attr %s %s %g",
                   at["tool"].str, at["name"].str, asDouble(at["value"])), cn);

        auto st = parseJSON(cast(string) get(BASE ~ "/api/tool/state"));
        foreach (string key, exp; cs["echo"].object) {
            assert(key in st, format("%s: tool/state missing echoed key '%s'", cn, key));
            assert(jApproxEq(exp, st[key], tol),
                format("%s: attr echo '%s' expected %s, got %s",
                       cn, key, exp.toString, st[key].toString));
        }

        if ("op" in cs)
            foreach (i, step; cs["op"].array) runStep(step, cn, "op", i);
        if ("derived_vertices" in cs) {
            auto got = readVertices();
            foreach (w; cs["derived_vertices"].array) {
                double[3] wp = jvec3(w);
                assert(hasVertexNear(got, wp, tol),
                    format("%s: derived vertex [%.4f,%.4f,%.4f] absent after "
                           ~ "attr edit (tol %.1e)", cn, wp[0], wp[1], wp[2], tol));
            }
        }
    }
}

// Canonical undirected-pair key for two vertex INDICES (order-independent).
private ulong indexPairKey(int a, int b) {
    uint lo = cast(uint)(a < b ? a : b);
    uint hi = cast(uint)(a < b ? b : a);
    return (cast(ulong)lo << 32) | hi;
}

/// `select-loop` verifier (task 0457): loads a captured mesh VERBATIM (vertex/
/// face order is preserved 1:1 by /api/load-mesh), selects a single seed edge
/// by its vertex-INDEX pair (into that same mesh — no coordinate matching
/// needed since the load is index-faithful), runs `select.loop`, then asserts
/// the resulting selected-edge SET equals the frozen `expected_edges` — also
/// given as vertex-index pairs, canonicalized order-independently. The golden
/// is the frozen reference capture's post-loop edge set (never vibe3d's own
/// output). Schema:
///   { "name": "...", "provenance": {...},
///     "cases": [ { "name": "...",
///                  "mesh": { "vertices": [[x,y,z],...], "faces": [[i,j,k,...],...] },
///                  "seed": [u, v],
///                  "expected_edges": [[a,b], [c,d], ...] } ] }
void runSelectLoopSuite(string fixtureJson) {
    auto fx      = parseJSON(fixtureJson);
    string suite = ("name" in fx) ? fx["name"].str : "<select-loop-suite>";
    requireProvenance(fx, suite);

    foreach (cs; fx["cases"].array) {
        string cn = suite ~ "/" ~ (("name" in cs) ? cs["name"].str : "<case>");

        post(BASE ~ "/api/reset?empty=true", "");
        auto lr = parseJSON(cast(string) post(BASE ~ "/api/command",
            commandBody("scene.loadMesh", cs["mesh"].toString)));
        if ("status" in lr) assert(lr["status"].str == "ok",
            format("%s: load-mesh failed: %s", cn, lr.toString));

        auto seedPair = cs["seed"].array;
        int su = cast(int) seedPair[0].integer, sv = cast(int) seedPair[1].integer;

        auto model = parseJSON(cast(string) get(BASE ~ "/api/model"));
        auto modelEdges = model["edges"].array;
        int seedIdx = -1;
        foreach (i, e; modelEdges) {
            auto ee = e.array;
            int a = cast(int) ee[0].integer, b = cast(int) ee[1].integer;
            if ((a == su && b == sv) || (a == sv && b == su)) { seedIdx = cast(int) i; break; }
        }
        assert(seedIdx >= 0,
            format("%s: seed edge (%d,%d) not found after load-mesh", cn, su, sv));

        auto selR = parseJSON(cast(string) post(BASE ~ "/api/command",
            commandBody("mesh.select",
                format(`{"mode":"edges","indices":[%d]}`, seedIdx))));
        if ("status" in selR) assert(selR["status"].str == "ok",
            format("%s: seed select failed: %s", cn, selR.toString));

        auto cmdR = parseJSON(cast(string) post(BASE ~ "/api/command", `{"id":"select.loop"}`));
        if ("status" in cmdR) assert(cmdR["status"].str == "ok",
            format("%s: select.loop command failed: %s", cn, cmdR.toString));

        auto sel    = parseJSON(cast(string) get(BASE ~ "/api/selection"));
        auto model2 = parseJSON(cast(string) get(BASE ~ "/api/model"));
        auto edges2 = model2["edges"].array;

        bool[ulong] got;
        foreach (si; sel["selectedEdges"].array) {
            long ei = si.integer;
            if (ei < 0 || ei >= cast(long) edges2.length) continue;
            auto ee = edges2[cast(size_t) ei].array;
            got[indexPairKey(cast(int) ee[0].integer, cast(int) ee[1].integer)] = true;
        }

        bool[ulong] want;
        foreach (ep; cs["expected_edges"].array) {
            auto pr = ep.array;
            want[indexPairKey(cast(int) pr[0].integer, cast(int) pr[1].integer)] = true;
        }

        assert(got.length == want.length,
            format("%s: edge-count mismatch — expected %d, got %d",
                   cn, want.length, got.length));
        foreach (k, _; want)
            assert((k in got) !is null,
                format("%s: expected edge (key %d) missing from selection", cn, k));
        foreach (k, _; got)
            assert((k in want) !is null,
                format("%s: unexpected extra edge (key %d) in selection", cn, k));
    }
}

/// select.loop face/vertex parity (task 0390) — polygon/vertex-mode
/// counterpart of runSelectLoopSuite. Cases carry `mode` ("vertex" |
/// "polygon"), a `seed` (vertex indices for vertex mode, polygon indices for
/// polygon mode — 1 or 2 entries) and `expected` (the frozen reference
/// selection as vertex/polygon indices, verbatim from the capture).
void runSelectLoopFvSuite(string fixtureJson) {
    auto fx      = parseJSON(fixtureJson);
    string suite = ("name" in fx) ? fx["name"].str : "<select-loop-fv-suite>";
    requireProvenance(fx, suite);

    foreach (cs; fx["cases"].array) {
        string cn   = suite ~ "/" ~ (("name" in cs) ? cs["name"].str : "<case>");
        string mode = cs["mode"].str;
        bool isVert = mode == "vertex";

        post(BASE ~ "/api/reset?empty=true", "");
        auto lr = parseJSON(cast(string) post(BASE ~ "/api/command",
            commandBody("scene.loadMesh", cs["mesh"].toString)));
        if ("status" in lr) assert(lr["status"].str == "ok",
            format("%s: load-mesh failed: %s", cn, lr.toString));

        string indices;
        foreach (i, s; cs["seed"].array) {
            if (i) indices ~= ",";
            indices ~= s.integer.to!string;
        }
        auto selR = parseJSON(cast(string) post(BASE ~ "/api/command",
            commandBody("mesh.select",
                format(`{"mode":"%s","indices":[%s]}`,
                       isVert ? "vertices" : "polygons", indices))));
        if ("status" in selR) assert(selR["status"].str == "ok",
            format("%s: seed select failed: %s", cn, selR.toString));

        auto cmdR = parseJSON(cast(string) post(BASE ~ "/api/command", `{"id":"select.loop"}`));
        if ("status" in cmdR) assert(cmdR["status"].str == "ok",
            format("%s: select.loop command failed: %s", cn, cmdR.toString));

        auto sel = parseJSON(cast(string) get(BASE ~ "/api/selection"));
        string key = isVert ? "selectedVertices" : "selectedFaces";

        bool[long] got;
        foreach (si; sel[key].array) got[si.integer] = true;
        bool[long] want;
        foreach (si; cs["expected"].array) want[si.integer] = true;

        assert(got.length == want.length,
            format("%s: selection-count mismatch — expected %d, got %d",
                   cn, want.length, got.length));
        foreach (k, _; want)
            assert((k in got) !is null,
                format("%s: expected %s %d missing from selection", cn, mode, k));
        foreach (k, _; got)
            assert((k in want) !is null,
                format("%s: unexpected extra %s %d in selection", cn, mode, k));
    }
}

// GET /api/model?layer=N and return its vertices as [x,y,z] doubles —
// the layer-scoped counterpart to readVertices() (which always reads the
// PRIMARY layer). Background-surface raycast fixtures need to resolve
// nearestVert/nearestEdge expectations against a NON-primary (background)
// layer's own geometry.
private double[3][] readVerticesInLayer(int layer) {
    auto model = parseJSON(cast(string) get(BASE ~ format("/api/model?layer=%d", layer)));
    auto arr = model["vertices"].array;
    auto outv = new double[3][](arr.length);
    foreach (i, v; arr) {
        auto c = v.array;
        outv[i] = [asDouble(c[0]), asDouble(c[1]), asDouble(c[2])];
    }
    return outv;
}

// Resolve a world-space vertex coordinate to its index within `layer`'s
// OWN mesh (mirrors resolveCoords's engine-neutral coordinate lookup, but
// layer-scoped instead of primary-only).
private int resolveVertexInLayer(int layer, double[3] coord, string ctx) {
    auto V = readVerticesInLayer(layer);
    foreach (i, v; V) if (veq(v, coord)) return cast(int) i;
    assert(false, format("%s: no vertex at %s in layer %d", ctx, coord, layer));
}

// Resolve a world-space edge (endpoint pair, either order) to its index
// within `layer`'s own mesh.
private int resolveEdgeInLayer(int layer, double[3] a, double[3] b, string ctx) {
    auto model = parseJSON(cast(string) get(BASE ~ format("/api/model?layer=%d", layer)));
    auto V = model["vertices"].array;
    double[3] vpos(long i) { return jvec3(V[cast(size_t) i]); }
    foreach (i, e; model["edges"].array) {
        auto ee = e.array;
        double[3] ea = vpos(ee[0].integer), eb = vpos(ee[1].integer);
        if ((veq(ea, a) && veq(eb, b)) || (veq(ea, b) && veq(eb, a)))
            return cast(int) i;
    }
    assert(false, format("%s: no edge (%s,%s) in layer %d", ctx, a, b, layer));
}

/// `surface-raycast` verifier (topology-pen P0, doc/topopen_p0_plan.md).
/// Runs `input` (background-layer setup + explicit camera placement via
/// the existing engine-neutral step vocabulary, including the "camera"
/// endpoint mapping above), fires GET /api/surface-raycast?x=&y= at the
/// case's `raycast` pixel, and asserts the JSON result against `expected`.
///
/// `nearestVert`/`nearestEdge` expectations are given as WORLD COORDINATES
/// — resolved to indices via GET /api/model?layer=N (N = `expected.layer`,
/// or the live response's own `layer` when `expected.layer` is omitted),
/// mirroring resolveCoords's engine-neutral coordinate-based lookup —
/// rather than hard-coded raw indices.
///
/// Camera placement trick used by every case's golden (see the fixture
/// authoring notes in tests/fixtures/topo_pen_*.json): the viewport CENTER
/// pixel's ray passes through the camera's `focus` point EXACTLY, by
/// construction of the lookAt-based camera (forward = normalize(focus -
/// eye); the ray hits `focus` at ray-parameter t = distance) — regardless
/// of azimuth/elevation/distance. So a case sets `focus` to the EXACT
/// world point it wants the raycast to land on, and rays at the viewport
/// centre pixel land there (within a small sub-pixel-rounding tolerance —
/// `pickSurface` samples the pixel CENTER, `mx+0.5`).
///
/// Schema:
///   { "name": "...", "provenance": {...}, "tolerance": 1e-2,
///     "cases": [ { "name": "...",
///                  "input": [ ...existing step vocabulary, plus
///                             {"endpoint":"camera","body":{...}}... ],
///                  "raycast": { "x": 475, "y": 300 },
///                  "expected": {
///                    "hit": true, "layer": 1, "face": 4,
///                    "point": [0,0.5,0], "normal": [0,1,0],
///                    "nearestVert": [0.5,0.5,-0.5],
///                    "nearestEdge": [[0.5,0.5,-0.5],[0.5,0.5,0.5]]
///                  } } ] }
/// `hit:false` cases only assert the miss — no other `expected` field is
/// read (there is no point/normal/face to check on a miss).
void runSurfaceRaycastSuite(string fixtureJson) {
    auto fx      = parseJSON(fixtureJson);
    string suite = ("name" in fx) ? fx["name"].str : "<surface-raycast-suite>";
    requireProvenance(fx, suite);
    double tolD  = ("tolerance" in fx) ? asDouble(fx["tolerance"]) : 1e-2;

    foreach (cs; fx["cases"].array) {
        string cn  = suite ~ "/" ~ (("name" in cs) ? cs["name"].str : "<case>");
        double tol = ("tolerance" in cs) ? asDouble(cs["tolerance"]) : tolD;

        foreach (i, step; cs["input"].array) runStep(step, cn, "input", i);

        auto rc = cs["raycast"];
        int rx = cast(int) rc["x"].integer;
        int ry = cast(int) rc["y"].integer;
        auto got = parseJSON(cast(string) get(
            BASE ~ format("/api/surface-raycast?x=%d&y=%d", rx, ry)));
        assert("error" !in got,
            format("%s: /api/surface-raycast error: %s", cn, got.toString));

        auto exp = cs["expected"];
        bool wantHit = ("hit" !in exp) || exp["hit"].type == JSONType.true_;
        bool gotHit  = "hit" in got && got["hit"].type == JSONType.true_;
        assert(gotHit == wantHit,
            format("%s: hit expected %s, got %s", cn, wantHit, got.toString));

        if (!wantHit) continue;   // a documented miss — nothing else to check

        if ("layer" in exp)
            assert(got["layer"].integer == exp["layer"].integer,
                format("%s: layer expected %d, got %s",
                       cn, exp["layer"].integer, got.toString));
        if ("face" in exp)
            assert(got["face"].integer == exp["face"].integer,
                format("%s: face expected %d, got %s",
                       cn, exp["face"].integer, got.toString));
        if ("point" in exp) {
            double[3] w = jvec3(exp["point"]);
            double[3] g = jvec3(got["point"]);
            assert(dist2(w, g) <= tol * tol,
                format("%s: point expected %s, got %s (tol %.1e)", cn, w, g, tol));
        }
        if ("normal" in exp) {
            double[3] w = jvec3(exp["normal"]);
            double[3] g = jvec3(got["normal"]);
            assert(dist2(w, g) <= tol * tol,
                format("%s: normal expected %s, got %s (tol %.1e)", cn, w, g, tol));
        }

        // `expected.layer` (asserted above against the response) IS the
        // Document-layer index /api/model?layer=N expects (NIT-3: the CONS
        // stage resolves its bgSrc-order slot to the real Document-layer
        // index at publish time via snap.backgroundSourceLayerIndices(),
        // so the packet's `layer` field and the Document index coincide —
        // no separate `docLayer` field needed). Falls back to the live
        // response's own `layer` when a case omits `expected.layer`.
        int layerForLookup = ("layer" in exp) ? cast(int) exp["layer"].integer
                                               : cast(int) got["layer"].integer;
        if ("nearestVert" in exp) {
            double[3] wv = jvec3(exp["nearestVert"]);
            int wantIdx = resolveVertexInLayer(layerForLookup, wv, cn);
            assert(got["nearestVert"].integer == wantIdx,
                format("%s: nearestVert expected idx %d (coord %s), got %d",
                       cn, wantIdx, wv, got["nearestVert"].integer));
        }
        if ("nearestEdge" in exp) {
            auto pr = exp["nearestEdge"].array;
            double[3] wa = jvec3(pr[0]), wb = jvec3(pr[1]);
            int wantIdx = resolveEdgeInLayer(layerForLookup, wa, wb, cn);
            assert(got["nearestEdge"].integer == wantIdx,
                format("%s: nearestEdge expected idx %d, got %d",
                       cn, wantIdx, got["nearestEdge"].integer));
        }
    }
}

/// `hover-target` verifier (topology-pen P1, doc/topopen_p1_plan.md). Same
/// step vocabulary + camera "focus-point trick" as `runSurfaceRaycastSuite`
/// (above), but asserts the RESOLVED hover snap-target
/// (`targetKind`/`targetVert`/`targetEdge`, `constraint.resolveHoverTarget`)
/// instead of the raw hit fields.
///
/// Schema:
///   { "name": "...", "provenance": {...},
///     "cases": [ { "name": "...",
///                  "input": [ ...existing step vocabulary... ],
///                  "raycast": { "x": 475, "y": 300, "thresholdPx": 60 },
///                  "expected": {
///                    "hit": true,                      // optional, default true
///                    "targetKind": "vertex",            // "none"|"vertex"|"edge"|"face"
///                    "targetVert": [x,y,z],             // world coord, vertex-only
///                    "targetEdge": [[x,y,z],[x,y,z]],   // world coords, edge-only
///                    "docLayer": 1                      // optional, default = response's own "layer"
///                  } } ] }
/// `raycast.thresholdPx` is optional — omitted means "use the tool's own
/// default" (the endpoint applies `topoPenPressPickPx(vp)`). `targetKind`
/// "face"/"none" cases skip the targetVert/targetEdge check (there is no
/// element to resolve — both are -1 by convention).
void runHoverTargetSuite(string fixtureJson) {
    auto fx      = parseJSON(fixtureJson);
    string suite = ("name" in fx) ? fx["name"].str : "<hover-target-suite>";
    requireProvenance(fx, suite);

    foreach (cs; fx["cases"].array) {
        string cn = suite ~ "/" ~ (("name" in cs) ? cs["name"].str : "<case>");

        foreach (i, step; cs["input"].array) runStep(step, cn, "input", i);

        auto rc = cs["raycast"];
        int rx = cast(int) rc["x"].integer;
        int ry = cast(int) rc["y"].integer;
        string url = BASE ~ format("/api/surface-raycast?x=%d&y=%d", rx, ry);
        if ("thresholdPx" in rc)
            url ~= format("&thresholdPx=%.6f", asDouble(rc["thresholdPx"]));
        auto got = parseJSON(cast(string) get(url));
        assert("error" !in got,
            format("%s: /api/surface-raycast error: %s", cn, got.toString));

        auto exp = cs["expected"];
        bool wantHit = ("hit" !in exp) || exp["hit"].type == JSONType.true_;
        bool gotHit  = "hit" in got && got["hit"].type == JSONType.true_;
        assert(gotHit == wantHit,
            format("%s: hit expected %s, got %s", cn, wantHit, got.toString));

        assert("targetKind" in exp, format("%s: case missing expected.targetKind", cn));
        string wantKind = exp["targetKind"].str;
        assert("targetKind" in got,
            format("%s: response missing targetKind: %s", cn, got.toString));
        string gotKind = got["targetKind"].str;
        assert(gotKind == wantKind,
            format("%s: targetKind expected %s, got %s (full: %s)",
                   cn, wantKind, gotKind, got.toString));

        if (wantKind == "face" || wantKind == "none")
            continue;   // no element resolved — targetVert/targetEdge are -1

        // Mirrors runSurfaceRaycastSuite's layer-lookup fallback: an
        // explicit `expected.docLayer` wins, otherwise fall back to the
        // live response's own `layer` field (still present — the P0
        // hit fields are unchanged/additive).
        int layerForLookup = ("docLayer" in exp) ? cast(int) exp["docLayer"].integer
                            : (("layer" in got) ? cast(int) got["layer"].integer : 1);

        if (wantKind == "vertex") {
            assert("targetVert" in exp, format("%s: vertex case missing expected.targetVert", cn));
            double[3] wv = jvec3(exp["targetVert"]);
            int wantIdx = resolveVertexInLayer(layerForLookup, wv, cn);
            assert("targetVert" in got, format("%s: response missing targetVert: %s", cn, got.toString));
            assert(got["targetVert"].integer == wantIdx,
                format("%s: targetVert expected idx %d (coord %s), got %d",
                       cn, wantIdx, wv, got["targetVert"].integer));
        } else if (wantKind == "edge") {
            assert("targetEdge" in exp, format("%s: edge case missing expected.targetEdge", cn));
            auto pr = exp["targetEdge"].array;
            double[3] wa = jvec3(pr[0]), wb = jvec3(pr[1]);
            int wantIdx = resolveEdgeInLayer(layerForLookup, wa, wb, cn);
            assert("targetEdge" in got, format("%s: response missing targetEdge: %s", cn, got.toString));
            assert(got["targetEdge"].integer == wantIdx,
                format("%s: targetEdge expected idx %d, got %d",
                       cn, wantIdx, got["targetEdge"].integer));
        }
    }
}

/// runSelectionSuite — a frozen SELECTION golden, keyed on geometry.
///
/// The suites above freeze positions after a geometry op; this one freezes
/// WHICH ELEMENTS ARE SELECTED after a selection command. The two cannot share
/// a runner: a selection golden has to survive a different vertex numbering
/// between the reference engine and vibe3d, so every expected element is
/// written as COORDINATES — a vertex as its position, an edge as its two
/// endpoint positions (either order), a polygon as its centroid — and matched
/// bidirectionally, exactly the way `runTopologyDiffSuite` matches vertices.
///
/// Schema:
///   { "name": "...", "provenance": {...}, "tolerance": 1e-4,
///     "cases": [ { "name": "...",
///                  "input": [ ...step vocabulary, including
///                             {"endpoint":"command","body":{...}}... ],
///                  "expected": {
///                    "mode":     "edges",                     // optional
///                    "edges":    [ [[x,y,z],[x,y,z]], ... ],  // optional
///                    "vertices": [ [x,y,z], ... ],            // optional
///                    "polygons": [ [cx,cy,cz], ... ]          // optional
///                  } } ] }
///
/// An omitted `expected` key is NOT "expect nothing" — it is "do not look".
/// Write `"edges": []` to assert an empty edge selection; that distinction is
/// load-bearing, because "the command selected nothing" is a real measured
/// outcome for several `select.boundary` cases and has to be assertable.
void runSelectionSuite(string fixtureJson) {
    auto fx      = parseJSON(fixtureJson);
    string suite = ("name" in fx) ? fx["name"].str : "<selection-suite>";
    requireProvenance(fx, suite);
    double tolD  = ("tolerance" in fx) ? asDouble(fx["tolerance"]) : 1e-4;

    foreach (cs; fx["cases"].array) {
        string cn  = suite ~ "/" ~ (("name" in cs) ? cs["name"].str : "<case>");
        double tol = ("tolerance" in cs) ? asDouble(cs["tolerance"]) : tolD;

        foreach (i, step; cs["input"].array) runStep(step, cn, "input", i);

        auto model = parseJSON(cast(string) get(BASE ~ "/api/model"));
        auto sel   = parseJSON(cast(string) get(BASE ~ "/api/selection"));
        auto V     = model["vertices"].array;
        double[3] vpos(long i) { return jvec3(V[cast(size_t) i]); }

        auto exp = cs["expected"];

        if ("mode" in exp)
            assert(sel["mode"].str == exp["mode"].str,
                format("%s: selection mode expected '%s', got '%s'",
                       cn, exp["mode"].str, sel["mode"].str));

        // ---- edges: unordered set of endpoint-position PAIRS -------------
        if ("edges" in exp) {
            double[3][2][] got;
            foreach (si; sel["selectedEdges"].array) {
                long ei = si.integer;
                auto ee = model["edges"].array[cast(size_t) ei].array;
                got ~= [vpos(ee[0].integer), vpos(ee[1].integer)];
            }
            auto want = exp["edges"].array;
            bool samePair(double[3][2] g, JSONValue w) {
                double[3] a = jvec3(w.array[0]), b = jvec3(w.array[1]);
                return (dist2(g[0], a) <= tol*tol && dist2(g[1], b) <= tol*tol)
                    || (dist2(g[0], b) <= tol*tol && dist2(g[1], a) <= tol*tol);
            }
            assert(got.length == want.length,
                format("%s: edge-selection size expected %d, got %d (%s)",
                       cn, want.length, got.length, got));
            foreach (w; want) {
                bool found = false;
                foreach (g; got) if (samePair(g, w)) { found = true; break; }
                assert(found, format("%s: expected edge %s not selected",
                                     cn, w.toString));
            }
            foreach (g; got) {
                bool found = false;
                foreach (w; want) if (samePair(g, w)) { found = true; break; }
                assert(found, format("%s: unexpected edge %s in the selection",
                                     cn, g));
            }
        }

        // ---- vertices: unordered set of positions ------------------------
        if ("vertices" in exp) {
            double[3][] got;
            foreach (si; sel["selectedVertices"].array)
                got ~= vpos(si.integer);
            auto want = exp["vertices"].array;
            assert(got.length == want.length,
                format("%s: vertex-selection size expected %d, got %d",
                       cn, want.length, got.length));
            foreach (w; want)
                assert(hasVertexNear(got, jvec3(w), tol),
                    format("%s: expected vertex %s not selected", cn, w.toString));
        }

        // ---- polygons: unordered set of centroids ------------------------
        if ("polygons" in exp) {
            double[3][] got;
            foreach (si; sel["selectedFaces"].array) {
                auto fv = model["faces"].array[cast(size_t) si.integer].array;
                double[3] c = [0, 0, 0];
                foreach (fi; fv) {
                    auto p = vpos(fi.integer);
                    c[0] += p[0]; c[1] += p[1]; c[2] += p[2];
                }
                double n = cast(double) fv.length;
                if (n > 0) { c[0] /= n; c[1] /= n; c[2] /= n; }
                got ~= c;
            }
            auto want = exp["polygons"].array;
            assert(got.length == want.length,
                format("%s: polygon-selection size expected %d, got %d",
                       cn, want.length, got.length));
            foreach (w; want)
                assert(hasVertexNear(got, jvec3(w), tol),
                    format("%s: expected polygon centroid %s not selected",
                           cn, w.toString));
        }
    }
}

// --------------------------------------------------------------------------
// Face-ring and material-partition comparison (task 1140).
//
// Both live here rather than in the divergence runner because both are
// COORDINATE-keyed set comparisons: element indices are not a promise across
// engines (nor across two of our own builds after a topology change), so a
// face is identified by the coordinates of its ring and a material group by
// the centroids of the faces that carry the tag. No tag VALUE is ever
// compared — the reference's tag names and our material ids are two private
// namespaces, and only the partition they induce is a shared fact.
// --------------------------------------------------------------------------

// GET /api/model and return each face as its ring of vertex COORDINATES.
private double[3][][] readFaceRings() {
    auto model = parseJSON(cast(string) get(BASE ~ "/api/model"));
    auto V = model["vertices"].array;
    double[3][][] outf;
    foreach (f; model["faces"].array) {
        double[3][] ring;
        foreach (fi; f.array) ring ~= jvec3(V[cast(size_t) fi.integer]);
        outf ~= ring;
    }
    return outf;
}

// GET /api/model and return the face partition induced by `faceMaterial`, as
// groups of face centroids. Group ORDER is not meaningful (it follows whatever
// order the tag values happen to sort in); comparison is by set, below.
private double[3][][] readMaterialGroups() {
    auto model = parseJSON(cast(string) get(BASE ~ "/api/model"));
    auto V = model["vertices"].array;
    auto faces = model["faces"].array;
    long[] mat;
    if ("faceMaterial" in model)
        foreach (m; model["faceMaterial"].array) mat ~= m.integer;
    double[3][][long] byTag;
    foreach (i, f; faces) {
        double[3] c = [0, 0, 0];
        auto fv = f.array;
        foreach (fi; fv) {
            auto p = jvec3(V[cast(size_t) fi.integer]);
            c[0] += p[0]; c[1] += p[1]; c[2] += p[2];
        }
        double n = cast(double) fv.length;
        if (n > 0) { c[0] /= n; c[1] /= n; c[2] /= n; }
        long tag = (i < mat.length) ? mat[i] : 0;
        byTag[tag] ~= c;
    }
    double[3][][] outg;
    foreach (k; byTag.keys.dup.sort()) outg ~= byTag[k];
    return outg;
}

private double[3][] jring(JSONValue v) {
    double[3][] r;
    foreach (p; v.array) r ~= jvec3(p);
    return r;
}

private string ringStr(const double[3][] r) {
    string s = "[";
    foreach (i, p; r) {
        if (i) s ~= " ";
        s ~= format("(%.4f,%.4f,%.4f)", p[0], p[1], p[2]);
    }
    return s ~ "]";
}

// Two rings are the same face iff they have the same length and agree
// position-by-position under SOME rotation. Rotation only, never reversal:
// where a ring starts is a storage detail, which way it goes round is not.
private bool ringEq(const double[3][] a, const double[3][] b, double tol) {
    if (a.length != b.length) return false;
    immutable n = a.length;
    if (n == 0) return true;
    immutable double t2 = tol * tol;
    foreach (r; 0 .. n) {
        bool ok = true;
        foreach (i; 0 .. n) {
            double[3] x = a[i], y = b[(i + r) % n];
            if (dist2(x, y) > t2) { ok = false; break; }
        }
        if (ok) return true;
    }
    return false;
}

// Two rings equal as SEQUENCES: same length, same order, and the SAME START.
// This is the reading `ringEq` deliberately does NOT provide, and the gap
// between the two is a measured blind spot (task 1280): on a convex QUAD the
// reference's two triangulators emit the same two triangles with the same
// winding and the same diagonal, differing only in where each tuple begins.
// Every face comparison in this file matches rings up to rotation, so that
// difference is invisible to all of them -- which is why a case that wants to
// assert it has to say `face_tuples` and get this instead.
private bool ringEqExact(const double[3][] a, const double[3][] b, double tol) {
    if (a.length != b.length) return false;
    immutable double t2 = tol * tol;
    foreach (i; 0 .. a.length) {
        double[3] x = a[i], y = b[i];
        if (dist2(x, y) > t2) return false;
    }
    return true;
}

// `ringsMissing`'s exact-start twin, same at-most-once matching.
private double[3][][] tuplesMissing(const double[3][][] a, const double[3][][] b,
                                    double tol) {
    auto used = new bool[](b.length);
    double[3][][] outr;
    foreach (ra; a) {
        bool hit = false;
        foreach (i, rb; b) {
            if (used[i]) continue;
            if (ringEqExact(ra, rb, tol)) { used[i] = true; hit = true; break; }
        }
        if (!hit) outr ~= ra.dup;
    }
    return outr;
}

// The rings of `a` that `b` cannot match, matching each `b` ring at most once
// (so a duplicated face is a difference, not a free pass).
private double[3][][] ringsMissing(const double[3][][] a, const double[3][][] b,
                                   double tol) {
    auto used = new bool[](b.length);
    double[3][][] outr;
    foreach (ra; a) {
        bool hit = false;
        foreach (j, rb; b) {
            if (used[j]) continue;
            if (ringEq(ra, rb, tol)) { used[j] = true; hit = true; break; }
        }
        if (!hit) outr ~= ra.dup;
    }
    return outr;
}

// ---------------------------------------------------------------------------
// RING-START STRENGTH — every face green must SAY what it covers (task 1310)
// ---------------------------------------------------------------------------
//
// `ringEq` above matches a ring under ANY rotation. That is a deliberate
// reading, but until this block existed it was also an INVISIBLE one: opening
// a fixture, or reading a green run, told you nothing about whether "our faces
// match the reference's" included where each ring begins. It twice did not,
// and twice the green was quoted as evidence anyway (see
// `doc/tasks/work/1283-fixture-comparison-ignores-tuple-start.md`).
//
// So a fixture that compares face rings must now declare, per fixture and
// optionally per case:
//
//   "face_ring_start": "compared"   rings are matched START-AND-ALL
//                                   (`ringEqExact`); a green here says our
//                                   ring begins at the same vertex as the
//                                   frozen one.
//   "face_ring_start": "ignored"    rings are matched up to rotation
//                                   (`ringEq`); a green says NOTHING about
//                                   where a ring starts, and
//                                   "face_ring_start_note" must say why that
//                                   is the right reading here.
//
// A case may override the fixture; an `ignored` case under a `compared`
// fixture must carry its OWN note, because that case is the exception and the
// exception is what needs explaining.
//
// The declaration is REQUIRED — a missing one is a hard failure, not a
// default. The point is that the next fixture cannot be silent about this
// either: whoever adds one has to answer the question the first time rather
// than leave a reader to infer it from a matcher three files away.
//
// Each suite additionally prints ONE summary line (see `ringStartSummary`),
// naming the reading it used and — for `ignored` — how many frozen rings
// would have failed the strict match. That number is the size of the blind
// spot, printed rather than argued.
private enum string RING_START_KEY  = "face_ring_start";
private enum string RING_START_NOTE = "face_ring_start_note";

private struct RingStartDecl {
    bool   compared;   // true  => match with ringEqExact, false => ringEq
    string note;       // required when !compared
}

// What one suite did with its face channel, accumulated across cases and
// printed once at the end.
private struct RingStartTally {
    string suite;
    size_t cases;        // cases that actually compared face rings
    size_t rings;        // frozen rings compared, summed over those cases
    size_t comparedCases;
    size_t ignoredCases;
    size_t wouldDiffer;  // rings that a strict match would REJECT (ignored cases only)
    string firstNote;
}

// Read + validate the declaration for one case. `fx` is the fixture root,
// `cs` the case; `cn` is the case's display name for messages.
private RingStartDecl ringStartDeclOf(JSONValue fx, JSONValue cs, string cn) {
    string fVal  = (RING_START_KEY  in fx) ? fx[RING_START_KEY].str  : "";
    string fNote = (RING_START_NOTE in fx) ? fx[RING_START_NOTE].str : "";
    string cVal  = (RING_START_KEY  in cs) ? cs[RING_START_KEY].str  : "";
    string cNote = (RING_START_NOTE in cs) ? cs[RING_START_NOTE].str : "";

    string val = cVal.length ? cVal : fVal;
    assert(val.length, format(
        "%s: this case compares FACE RINGS, but neither the case nor the "
        ~ "fixture declares \"%s\". Face rings are matched up to ROTATION "
        ~ "unless a fixture says otherwise, so a green here may or may not "
        ~ "cover where each ring STARTS — and a reader cannot tell which. "
        ~ "Declare \"%s\": \"compared\" (strict, start included) or "
        ~ "\"ignored\" (rotation-tolerant) plus a \"%s\" saying why. "
        ~ "See doc/tasks/work/1283-fixture-comparison-ignores-tuple-start.md",
        cn, RING_START_KEY, RING_START_KEY, RING_START_NOTE));
    assert(val == "compared" || val == "ignored", format(
        "%s: \"%s\" is '%s'; the only readings are \"compared\" (ringEqExact) "
        ~ "and \"ignored\" (ringEq, rotation-tolerant)", cn, RING_START_KEY, val));

    string note = cNote.length ? cNote : fNote;
    if (val == "ignored") {
        assert(note.length, format(
            "%s: \"%s\" is \"ignored\", so this fixture's face green does not "
            ~ "cover where a ring starts. Add \"%s\" saying why that is the "
            ~ "right reading here — an unexplained rotation-tolerant green is "
            ~ "exactly the blind spot this declaration exists to surface",
            cn, RING_START_KEY, RING_START_NOTE));
        // The EXCEPTION carries its own reason: a fixture-wide note written
        // for a "compared" fixture cannot also explain why one case is not.
        if (cVal == "ignored" && fVal == "compared")
            assert(cNote.length, format(
                "%s: this case downgrades a \"compared\" fixture to "
                ~ "\"ignored\", so it needs its OWN \"%s\" — the fixture-level "
                ~ "note describes the cases that DO compare starts",
                cn, RING_START_NOTE));
    }
    return RingStartDecl(val == "compared", note);
}

// `ringEq` or `ringEqExact`, chosen by the declaration. Spelled once so no
// call site has to remember which way round the flag reads.
private bool ringMatchBy(const double[3][] a, const double[3][] b,
                         double tol, bool exact) {
    return exact ? ringEqExact(a, b, tol) : ringEq(a, b, tol);
}

// `ringsMissing` / `tuplesMissing`, chosen by the same flag.
private double[3][][] ringsMissingBy(const double[3][][] a, const double[3][][] b,
                                     double tol, bool exact) {
    return exact ? tuplesMissing(a, b, tol) : ringsMissing(a, b, tol);
}

// Fold one case's outcome into the suite tally. `frozen` / `live` are the two
// ring lists the case just compared; for an `ignored` case the strict match is
// run a second time purely to MEASURE the gap the green is not covering.
private void ringStartAccrue(ref RingStartTally t, RingStartDecl d,
                             const double[3][][] frozen, const double[3][][] live,
                             double tol) {
    t.cases++;
    t.rings += frozen.length;
    if (d.compared) t.comparedCases++;
    else {
        t.ignoredCases++;
        t.wouldDiffer += tuplesMissing(frozen, live, tol).length;
    }
    if (!t.firstNote.length) t.firstNote = d.note;
}

// One line per suite, so a CI log distinguishes a strong face green from a
// rotation-tolerant one without anyone opening the fixture.
private void ringStartSummary(RingStartTally t) {
    if (t.cases == 0) return;
    import std.stdio : writefln, stdout;
    string reading;
    if (t.ignoredCases == 0)      reading = "ring start COMPARED";
    else if (t.comparedCases == 0) reading = "ring start IGNORED";
    else reading = format("ring start COMPARED in %d of %d cases",
                          t.comparedCases, t.cases);
    string gap = t.ignoredCases
        ? format("; %d ring(s) in the %d rotation-tolerant case(s) would fail a "
                 ~ "strict match%s", t.wouldDiffer, t.ignoredCases,
                 t.wouldDiffer == 0
                     ? " -- none, so those cases are convertible to \"compared\"" : "")
        : "";
    writefln("[face-ring-start] %s: %d case(s), %d frozen ring(s), %s%s",
             t.suite, t.cases, t.rings, reading, gap);
    stdout.flush();   // parallel workers interleave otherwise
}

// Same-set test for two groups of centroids (order-independent, tolerance).
private bool centroidSetEq(const double[3][] a, const double[3][] b, double tol) {
    if (a.length != b.length) return false;
    auto used = new bool[](b.length);
    immutable double t2 = tol * tol;
    foreach (pa; a) {
        bool hit = false;
        foreach (j, pb; b) {
            if (used[j]) continue;
            double[3] x = pa, y = pb;
            if (dist2(x, y) <= t2) { used[j] = true; hit = true; break; }
        }
        if (!hit) return false;
    }
    return true;
}

// Two partitions are equal iff their groups pair up one-for-one. Group order
// carries no meaning, so this is a bijection test, not a list comparison.
private bool partitionEq(const double[3][][] a, const double[3][][] b, double tol) {
    if (a.length != b.length) return false;
    auto used = new bool[](b.length);
    foreach (ga; a) {
        bool hit = false;
        foreach (j, gb; b) {
            if (used[j]) continue;
            if (centroidSetEq(ga, gb, tol)) { used[j] = true; hit = true; break; }
        }
        if (!hit) return false;
    }
    return true;
}

private long[] groupSizes(const double[3][][] g) {
    long[] s;
    foreach (grp; g) s ~= cast(long) grp.length;
    s.sort();
    return s;
}

private double[3][][] jgroups(JSONValue v) {
    double[3][][] g;
    foreach (grp; v.array) {
        double[3][] c;
        foreach (p; grp.array) c ~= jvec3(p);
        g ~= c;
    }
    return g;
}

/// runKnownDivergenceSuite — freeze a MEASURED disagreement with the
/// reference, so it can neither rot nor be mistaken for parity.
///
/// Some reference behaviour is measured before we can reproduce it. The
/// measurement is the valuable part and must be committed; what must NOT
/// happen is committing it as a red parity test (it breaks the gate for
/// everyone) or as a green test of our own current output (which reads as
/// parity and quietly blesses the divergence).
///
/// This runner asserts THREE things, and each one fails for a different and
/// useful reason:
///   1. our output still matches `vibe3d_current`   — a plain regression pin;
///   2. the reference golden is still what it was   — the frozen measurement;
///   3. the difference between them is EXACTLY the declared `divergence`.
///
/// (3) is the load-bearing one. Narrow the gap and this suite goes red — which
/// is the intended prompt: whoever closed it updates the fixture, and if they
/// closed it completely they delete this case and add a parity one. A
/// divergence that has been quietly fixed is as much a stale record as one
/// that has quietly widened.
///
/// Schema:
///   { "name": "...", "provenance": {...}, "tolerance": 1e-4,
///     "cases": [ { "name": "...", "input": [...], "op": [...],
///                  "reference":      { "counts": {...}, "vertices": [...] },
///                  "vibe3d_current": { "counts": {...}, "vertices": [...] },
///                  "divergence": {
///                     "extra_in_vibe3d":   [ [x,y,z], ... ],
///                     "missing_in_vibe3d": [ [x,y,z], ... ] } } ] }
///
/// TWO OPTIONAL CHANNELS beyond the vertex one, because a divergence does not
/// have to live in the vertex set — and a suite that only knows how to look
/// there reports PARITY on the cases where it does not (task 1140):
///
///   `faces` — each face as its RING OF COORDINATES, compared up to ROTATION
///     only, so a ring stored from a different start index still matches but a
///     ring wound the other way does NOT. Winding is a real mesh property and
///     the whole divergence in some cells; a winding-blind comparison would
///     silently call those parity. Gap declared as
///     `extra_faces_in_vibe3d` / `missing_faces_in_vibe3d`.
///
///   `material_groups` — the PARTITION of faces by material tag, written as
///     groups of face CENTROIDS. Tag VALUES are engine-private and are never
///     compared; only which faces share a tag with which. Gap declared as
///     `divergence.material_partition.{reference,vibe3d}_group_sizes`, and the
///     runner additionally requires the two partitions to still DIFFER — a
///     material carry that started working reddens here. Once it is CLOSED and
///     the case converted (both frozen sides carrying the same partition, the
///     declared sizes equal), that requirement inverts: the runner then demands
///     the live partition MATCH the reference, so a re-opened gap reddens too.
///
/// Both are opt-in per case: a case that omits `faces` gets exactly the
/// pre-1140 vertex-only behaviour.
///
/// A case that DOES carry `faces` must also declare `face_ring_start`
/// ("compared" | "ignored" + a note; task 1310). "compared" re-reads the same
/// `faces` arrays with `ringEqExact` -- the regression pin AND the recomputed
/// gap -- so it can only be declared where the gap is identical under either
/// matcher, and needs no new numbers. `face_tuples` above stays the channel
/// for a gap that exists ONLY at tuple level and therefore needs its own
/// declared sets.
void runKnownDivergenceSuite(string fixtureJson) {
    auto fx      = parseJSON(fixtureJson);
    string suite = ("name" in fx) ? fx["name"].str : "<divergence-suite>";
    requireProvenance(fx, suite);
    double tolD  = ("tolerance" in fx) ? asDouble(fx["tolerance"]) : 1e-4;
    auto tally = RingStartTally(suite);
    scope (exit) ringStartSummary(tally);

    foreach (cs; fx["cases"].array) {
        string cn  = suite ~ "/" ~ (("name" in cs) ? cs["name"].str : "<case>");
        double tol = ("tolerance" in cs) ? asDouble(cs["tolerance"]) : tolD;

        foreach (i, step; cs["input"].array) runStep(step, cn, "input", i);
        foreach (i, step; cs["op"].array)    runStep(step, cn, "op", i);

        auto cur = cs["vibe3d_current"];
        if ("counts" in cur)
            assertCounts(cn, "vibe3d_current", cur["counts"], readCounts());

        auto got = readVertices();

        // (1) our own output, verbatim — bidirectional, so neither a lost nor
        // an invented vertex slips through.
        auto mine = cur["vertices"].array;
        foreach (w; mine)
            assert(hasVertexNear(got, jvec3(w), tol),
                format("%s: vibe3d no longer produces its recorded vertex %s "
                       ~ "— this fixture records a KNOWN DIVERGENCE; if you "
                       ~ "changed the behaviour deliberately, re-measure and "
                       ~ "update it", cn, w.toString));
        foreach (g; got) {
            bool found = false;
            foreach (w; mine) if (dist2(g, jvec3(w)) <= tol*tol) { found = true; break; }
            assert(found,
                format("%s: vibe3d produced a vertex [%.4f,%.4f,%.4f] that is "
                       ~ "not in its recorded output", cn, g[0], g[1], g[2]));
        }

        // (3) the gap itself. Recompute it from the two frozen sets rather
        // than trusting the declared list, then check the two agree — a
        // hand-edited `divergence` block that no longer describes the data is
        // exactly the stale record this suite exists to prevent.
        auto refv = cs["reference"]["vertices"].array;
        double[3][] extra, missing;
        foreach (g; got) {
            bool inRef = false;
            foreach (r; refv) if (dist2(g, jvec3(r)) <= tol*tol) { inRef = true; break; }
            if (!inRef) extra ~= g;
        }
        foreach (r; refv) {
            bool inGot = hasVertexNear(got, jvec3(r), tol);
            if (!inGot) missing ~= jvec3(r);
        }

        auto dv = cs["divergence"];
        void sameSet(string what, double[3][] have, JSONValue declared) {
            auto want = declared.array;
            assert(have.length == want.length,
                format("%s: %s is now %d vertices, the fixture declares %d "
                       ~ "(%s). The divergence CHANGED — re-measure against "
                       ~ "the reference and update this fixture; if it closed "
                       ~ "entirely, replace this case with a parity one.",
                       cn, what, have.length, want.length, have));
            foreach (w; want)
                assert(hasVertexNear(have, jvec3(w), tol),
                    format("%s: %s no longer contains %s — the divergence "
                           ~ "CHANGED, re-measure and update this fixture",
                           cn, what, w.toString));
        }
        sameSet("extra_in_vibe3d", extra,
                ("extra_in_vibe3d" in dv) ? dv["extra_in_vibe3d"] : JSONValue(cast(JSONValue[])[]));
        sameSet("missing_in_vibe3d", missing,
                ("missing_in_vibe3d" in dv) ? dv["missing_in_vibe3d"] : JSONValue(cast(JSONValue[])[]));

        // ---- optional FACE channel --------------------------------------
        // Present on the cases whose divergence is NOT in the vertex set —
        // where the two engines agree on every point and disagree only about
        // which points make a face, or which way round it goes.
        if ("faces" in cur) {
            // Task 1310: rotation-tolerant or start-and-all is a DECLARED
            // property of the case. Declaring "compared" here re-reads this
            // same channel with `ringEqExact` -- both the regression pin and
            // the recomputed gap -- so it can only be declared where the gap
            // is the same under either matcher, which is what makes it safe
            // to flip without touching the frozen numbers.
            auto rs   = ringStartDeclOf(fx, cs, cn);
            auto gotF = readFaceRings();
            double[3][][] mineF;
            foreach (r; cur["faces"].array) mineF ~= jring(r);

            // (1) our own faces, verbatim and bidirectional.
            auto lostMine = ringsMissingBy(mineF, gotF, tol, rs.compared);
            if (lostMine.length)
                assert(false,
                    format("%s: vibe3d no longer produces its recorded face %s "
                           ~ "(%d of %d gone) — this fixture records a KNOWN "
                           ~ "DIVERGENCE; if you changed the behaviour "
                           ~ "deliberately, re-measure and update it",
                           cn, ringStr(lostMine[0]), lostMine.length, mineF.length));
            auto newMine = ringsMissingBy(gotF, mineF, tol, rs.compared);
            if (newMine.length)
                assert(false,
                    format("%s: vibe3d produced a face %s that is not in its "
                           ~ "recorded output (%d such)", cn,
                           ringStr(newMine[0]), newMine.length));

            // (3) the face gap, recomputed from the two frozen sides.
            double[3][][] refF;
            foreach (r; cs["reference"]["faces"].array) refF ~= jring(r);
            auto extraF   = ringsMissingBy(gotF, refF, tol, rs.compared);
            auto missingF = ringsMissingBy(refF, gotF, tol, rs.compared);
            ringStartAccrue(tally, rs, refF, gotF, tol);

            void sameFaceSet(string what, double[3][][] have, JSONValue declared) {
                auto want = declared.array;
                assert(have.length == want.length,
                    format("%s: %s is now %d faces, the fixture declares %d. "
                           ~ "The divergence CHANGED — re-measure against the "
                           ~ "reference and update this fixture; if it closed "
                           ~ "entirely, replace this case with a parity one.",
                           cn, what, have.length, want.length));
                foreach (w; want) {
                    auto wr = jring(w);
                    bool found = false;
                    foreach (h; have) if (ringMatchBy(h, wr, tol, rs.compared)) { found = true; break; }
                    assert(found,
                        format("%s: %s no longer contains the face %s — the "
                               ~ "divergence CHANGED, re-measure and update "
                               ~ "this fixture", cn, what, ringStr(wr)));
                }
            }
            sameFaceSet("extra_faces_in_vibe3d", extraF,
                ("extra_faces_in_vibe3d" in dv) ? dv["extra_faces_in_vibe3d"]
                                                : JSONValue(cast(JSONValue[])[]));
            sameFaceSet("missing_faces_in_vibe3d", missingF,
                ("missing_faces_in_vibe3d" in dv) ? dv["missing_faces_in_vibe3d"]
                                                  : JSONValue(cast(JSONValue[])[]));
        }

        // ---- optional ORDERED FACE-TUPLE channel (task 1280) ------------
        // For the cells where both engines emit the SAME triangles, wound the
        // same way, and disagree only about where each tuple STARTS. Every
        // other face channel here matches rings up to rotation, so such a case
        // declares an empty gap in all of them and reads as parity; this one
        // compares the rings as sequences and can therefore carry it.
        if ("face_tuples" in cur) {
            auto gotT = readFaceRings();
            double[3][][] mineT;
            foreach (r; cur["face_tuples"].array) mineT ~= jring(r);

            auto lostT = tuplesMissing(mineT, gotT, tol);
            assert(lostT.length == 0,
                format("%s: vibe3d no longer emits its recorded face TUPLE %s "
                       ~ "(%d of %d gone). The triangles may still be the same "
                       ~ "set -- what moved is where a tuple starts, which is "
                       ~ "what this channel exists to see",
                       cn, lostT.length ? ringStr(lostT[0]) : "", lostT.length,
                       mineT.length));
            auto newT = tuplesMissing(gotT, mineT, tol);
            assert(newT.length == 0,
                format("%s: vibe3d emitted the face tuple %s, which is not in "
                       ~ "its recorded output (%d such)", cn,
                       newT.length ? ringStr(newT[0]) : "", newT.length));

            double[3][][] refT;
            foreach (r; cs["reference"]["face_tuples"].array) refT ~= jring(r);
            auto extraT   = tuplesMissing(gotT, refT, tol);
            auto missingT = tuplesMissing(refT, gotT, tol);

            void sameTupleSet(string what, double[3][][] have, JSONValue declared) {
                auto want = declared.array;
                assert(have.length == want.length,
                    format("%s: %s is now %d tuples, the fixture declares %d. "
                           ~ "The tuple-start divergence CHANGED -- re-measure; "
                           ~ "if it closed, this case becomes a parity one and "
                           ~ "the declaration comes out.",
                           cn, what, have.length, want.length));
                foreach (w; want) {
                    auto wr = jring(w);
                    bool found = false;
                    foreach (h; have) if (ringEqExact(h, wr, tol)) { found = true; break; }
                    assert(found,
                        format("%s: %s no longer contains the tuple %s",
                               cn, what, ringStr(wr)));
                }
            }
            sameTupleSet("extra_face_tuples_in_vibe3d", extraT,
                ("extra_face_tuples_in_vibe3d" in dv)
                    ? dv["extra_face_tuples_in_vibe3d"] : JSONValue(cast(JSONValue[])[]));
            sameTupleSet("missing_face_tuples_in_vibe3d", missingT,
                ("missing_face_tuples_in_vibe3d" in dv)
                    ? dv["missing_face_tuples_in_vibe3d"] : JSONValue(cast(JSONValue[])[]));
        }

        // ---- optional MATERIAL-PARTITION channel ------------------------
        // For the cells where the geometry is identical in both engines and
        // the disagreement is entirely about which faces inherit a tag.
        if ("material_groups" in cur) {
            auto gotG = readMaterialGroups();
            auto mineG = jgroups(cur["material_groups"]);
            auto refG  = jgroups(cs["reference"]["material_groups"]);

            // (1) our own partition, verbatim.
            assert(partitionEq(gotG, mineG, tol),
                format("%s: vibe3d's material partition is now %s, its "
                       ~ "recorded one is %s — this fixture records a KNOWN "
                       ~ "DIVERGENCE; if you changed the behaviour "
                       ~ "deliberately, re-measure and update it",
                       cn, groupSizes(gotG), groupSizes(mineG)));

            // (3) the gap: the declared sizes on both sides, AND that the two
            // partitions still differ at all. Sizes alone would go on passing
            // after a fix that reshuffled which faces carry which tag, and a
            // closed divergence must redden, not sit quietly green.
            if ("material_partition" in dv) {
                auto mp = dv["material_partition"];
                void sameSizes(string side, long[] have, JSONValue declared) {
                    long[] want;
                    foreach (w; declared.array) want ~= w.integer;
                    want.sort();
                    assert(have == want,
                        format("%s: %s material-group sizes are now %s, the "
                               ~ "fixture declares %s. The divergence CHANGED "
                               ~ "— re-measure and update this fixture.",
                               cn, side, have, want));
                }
                if ("reference_group_sizes" in mp)
                    sameSizes("reference", groupSizes(refG), mp["reference_group_sizes"]);
                if ("vibe3d_group_sizes" in mp)
                    sameSizes("vibe3d", groupSizes(gotG), mp["vibe3d_group_sizes"]);
            }
            // A case whose two FROZEN sides already agree is a CONVERTED one:
            // the divergence closed, the declaration was updated to an empty
            // gap, and what it now pins is parity. Asserting the two still
            // differ would make closing a divergence impossible to record
            // without deleting the case — and the case, with its input, its op
            // and its measured reference, is the part worth keeping (task
            // 1220). Which arm runs is derived from the fixture's own data, not
            // from a flag someone can set by hand.
            // A CONVERTED case needs no assertion of its own here, and adding
            // one would be inert: with the two frozen partitions equal, check
            // (1) above — live == `vibe3d_current` — IS the parity check, and
            // it fails first on any drift. What must not survive conversion is
            // the demand that the two still differ.
            if (!partitionEq(refG, mineG, tol))
                assert(!partitionEq(gotG, refG, tol),
                    format("%s: vibe3d's material partition now MATCHES the "
                           ~ "reference's. The divergence has CLOSED — convert "
                           ~ "this case: set `vibe3d_current.material_groups` "
                           ~ "to the reference's partition and declare the two "
                           ~ "group-size lists equal.", cn));
        }
        // ---- optional: the DISPLACEMENT law behind the vertex gap ---------
        // Some divergences are not "these vertices differ" but "both engines
        // move the same point by the same distance in different directions".
        // A set diff records the first and loses the second, so a case may
        // carry an `offset_law` block: per base corner, the vertex each engine
        // CREATED nearest to it, and therefore each engine's displacement.
        // Both offsets are re-derived here — the reference's from the frozen
        // golden, ours from the LIVE output — so the recorded magnitudes and
        // per-corner angles are checked, not merely stored.
        if ("offset_law" in cs) {
            auto ol = cs["offset_law"];
            double magTol = ("magnitudes_agree_within" in ol)
                          ? asDouble(ol["magnitudes_agree_within"]) : 1e-4;
            double angTol = ("angle_tolerance_deg" in ol)
                          ? asDouble(ol["angle_tolerance_deg"]) : 0.5;

            // The base corners are the vertices the input LOADED: a created
            // vertex is one that is not one of them.
            double[3][] basePts;
            foreach (step; cs["input"].array)
                if ("endpoint" in step && step["endpoint"].str == "load-mesh")
                    foreach (v; step["body"]["vertices"].array) basePts ~= jvec3(v);
            assert(basePts.length,
                format("%s: offset_law needs a load-mesh step to know which "
                       ~ "vertices are base corners", cn));

            double[3][] createdIn(double[3][] all) {
                double[3][] outv;
                foreach (v; all) {
                    bool isBase = false;
                    foreach (b; basePts) if (dist2(v, b) <= 1e-12) { isBase = true; break; }
                    if (!isBase) outv ~= v;
                }
                return outv;
            }
            double[3][] refCreated, ourCreated;
            foreach (r; refv) refCreated ~= jvec3(r);
            refCreated = createdIn(refCreated);
            ourCreated = createdIn(got);

            double[3] nearestTo(double[3][] pool, double[3] p, string what) {
                assert(pool.length, format("%s: %s created no vertices", cn, what));
                size_t best = 0; double bd = double.max;
                foreach (i, q; pool) { auto d = dist2(q, p); if (d < bd) { bd = d; best = i; } }
                return pool[best];
            }
            double vlen(double[3] v) { return sqrt(v[0]*v[0] + v[1]*v[1] + v[2]*v[2]); }
            double angleDeg(double[3] a, double[3] b) {
                double la = vlen(a), lb = vlen(b);
                if (la < 1e-12 || lb < 1e-12) return 0;
                double d = (a[0]*b[0] + a[1]*b[1] + a[2]*b[2]) / (la * lb);
                if (d > 1) d = 1; else if (d < -1) d = -1;
                return acos(d) * (180.0 / PI);
            }

            foreach (pr; ol["pairs"].array) {
                double[3] corner = jvec3(pr["corner"]);
                auto rv = nearestTo(refCreated, corner, "the reference");
                auto ov = nearestTo(ourCreated, corner, "vibe3d");
                double[3] ro = [rv[0]-corner[0], rv[1]-corner[1], rv[2]-corner[2]];
                double[3] oo = [ov[0]-corner[0], ov[1]-corner[1], ov[2]-corner[2]];
                double[3] wr = jvec3(pr["reference_offset"]);
                double[3] wo = jvec3(pr["vibe3d_offset"]);
                assert(dist2(ro, wr) <= tol*tol,
                    format("%s: at corner %s the reference golden's offset is "
                           ~ "[%.6f,%.6f,%.6f], the fixture declares %s",
                           cn, pr["corner"].toString, ro[0], ro[1], ro[2],
                           pr["reference_offset"].toString));
                assert(dist2(oo, wo) <= tol*tol,
                    format("%s: at corner %s vibe3d's offset is now "
                           ~ "[%.6f,%.6f,%.6f], the fixture froze %s",
                           cn, pr["corner"].toString, oo[0], oo[1], oo[2],
                           pr["vibe3d_offset"].toString));
                assert(fabs(vlen(ro) - vlen(oo)) <= magTol,
                    format("%s: at corner %s the two engines no longer move by "
                           ~ "the SAME distance (%.6f vs %.6f, tol %.1e) — that "
                           ~ "equality is the measured finding, so this is a "
                           ~ "different divergence and needs re-measuring",
                           cn, pr["corner"].toString, vlen(ro), vlen(oo), magTol));
                double ang = angleDeg(ro, oo);
                double wantAng = asDouble(pr["angle_deg"]);
                assert(fabs(ang - wantAng) <= angTol,
                    format("%s: at corner %s the directions now differ by "
                           ~ "%.3f deg, the fixture froze %.3f (tol %.2f)",
                           cn, pr["corner"].toString, ang, wantAng, angTol));
            }
        }
    }
}

// ===========================================================================
// runRingOrbitSuite — task 1150: freeze a RING-ORDER finding, whose unit of
// evidence is an ORBIT and not a single mesh.
// ===========================================================================
//
// Everything in this family was found by emitting ONE geometry once per
// starting index of its vertex ring and running the same op on every member.
// The vertex array is byte-identical across an orbit; only the ring order
// moves. A fixture that pinned a single rotation would lose the finding
// outright — in the run these came from, sixteen apparent parities were
// caught precisely because the FIRST member of an orbit agreed while a later
// one did not.
//
// So one case here is n runs, and what it freezes is the orbit's PATTERN:
// first-appearance class labels over the rotations, e.g. `0000` = "the answer
// does not depend on where the ring starts at all", `0101` = "period two",
// `010020` = "three different answers, and which one you get is decided by
// what kind of corner the ring happens to start at".
//
// THREE CHANNELS, because two of the findings live in only one of them, and
// named to match task 1140's divergence runner so one word does not mean two
// things in one file:
//   vertices          — the multiset of vertex positions;
//   faces             — the multiset of face rings, compared up to ROTATION
//                       only, so winding is visible;
//   faces_any_winding — the same, also accepting the reversed ring.
// A triangulation that returns the same triangles wound the other way is
// invariant in `faces_any_winding` and dependent in `faces`; a fixture with
// one channel could not say that, and the difference is a measured finding
// (the reference's triangle SET does not follow the ring start, its WINDING
// does).
//
// What is asserted, and what each failure means:
//   1. every rotation's own output, verbatim (counts, vertex multiset, face
//      rings with winding) — a plain regression pin;
//   2. whether our op APPLIED at all, re-derived from the data (output ==
//      the mesh the input loaded ⇒ no-op) rather than taken on trust;
//   3. our orbit patterns, recomputed live in all three channels;
//   4. the reference's orbit patterns, recomputed from the frozen reference
//      blocks — so a hand-edited pattern that no longer describes its own
//      data fails here rather than lying;
//   5. the case's `kind` (who reads the ring), re-derived from 3+4+2;
//   6. where present, the SIGN PREDICATE — `sign(cross(r1-r0, r[n-1]-r0) ·
//      Newell(ring))`, "is the corner at ring index 0 convex with respect to
//      the ring's own normal" — recomputed in this runner from the fixture's
//      own base rings, and its declared relation to the reference's pattern
//      (exact / refines / violated).
//
// A green run means the divergence is still exactly the shape it was measured
// to be. It reddens when the gap moves in EITHER direction, including when
// someone closes it — which is the prompt to convert the case to parity.

// One rotation's answer, in the form every comparator below reads.
private struct OrbitAnswer {
    double[3][]   verts;
    double[3][][] faces;
}

// `readFaceRings`, `ringEq` (rotation only, never reversal) and
// `centroidSetEq` (an order-free point-set match) are task 1140's, defined
// with the divergence runner above; they are exactly what an orbit needs and
// are reused rather than re-implemented. The ONE thing this suite needs that
// they do not provide is the reflection-tolerant reading, below.

// Two rings are the same face IGNORING which way round they go. `ringEq` is
// the winding-RESPECTING reading; this is its complement, and keeping the two
// apart is a measured requirement, not tidiness: the reference's
// triangulation returns the same triangles wound the other way when the ring
// start moves, so it is invariant in this channel and dependent in that one.
private bool ringEqAnyWinding(const double[3][] a, const double[3][] b, double tol) {
    if (ringEq(a, b, tol)) return true;
    double[3][] rb;
    foreach_reverse (v; b) rb ~= v;
    return ringEq(a, rb, tol);
}

private bool faceSetsEqual(double[3][][] A, double[3][][] B, bool wound, double tol) {
    if (A.length != B.length) return false;
    // The winding-respecting reading IS task 1140's `ringsMissing` matcher —
    // called, not re-spelled. Only the reflection-tolerant reading needs its
    // own loop, because no lane has that comparison yet.
    if (wound) return ringsMissing(A, B, tol).length == 0;
    auto used = new bool[](B.length);
    foreach (fa; A) {
        bool hit = false;
        foreach (i, fb; B) {
            if (used[i]) continue;
            if (ringEqAnyWinding(fa, fb, tol)) { used[i] = true; hit = true; break; }
        }
        if (!hit) return false;
    }
    return true;
}

// The channels, named to match task 1140's runner: `faces` respects winding
// (rotation only), `faces_any_winding` does not, and `face_tuples` (task
// 1310) respects the ring START as well -- the reading under which "the same
// two triangles, begun at a different corner" is a DIFFERENT answer. That
// last one is not a refinement for its own sake: on this fixture it splits
// classes the other three merge in 13 of 16 cases, and on two of them the two
// engines' tuple orbits differ where their ring-set orbits agree.
private bool sameAnswer(OrbitAnswer x, OrbitAnswer y, string channel, double tol) {
    if (!centroidSetEq(x.verts, y.verts, tol)) return false;
    if (channel == "vertices") return true;
    if (channel == "face_tuples")
        return x.faces.length == y.faces.length
            && tuplesMissing(x.faces, y.faces, tol).length == 0;
    return faceSetsEqual(x.faces, y.faces, channel == "faces", tol);
}

// First-appearance class labels over the orbit: "0101" says rotations 0 and 2
// agreed and rotations 1 and 3 agreed with each other but not with them.
private string orbitPattern(OrbitAnswer[] answers, string channel, double tol) {
    OrbitAnswer[] reps;
    string outp;
    foreach (a; answers) {
        long hit = -1;
        foreach (i, r; reps) if (sameAnswer(a, r, channel, tol)) { hit = cast(long) i; break; }
        if (hit < 0) { reps ~= a; hit = cast(long) reps.length - 1; }
        outp ~= format("%d", hit);
    }
    return outp;
}

private double[3] newellNormal(double[3][] ring) {
    double[3] n = [0.0, 0.0, 0.0];
    immutable m = ring.length;
    foreach (i; 0 .. m) {
        auto p = ring[i], q = ring[(i + 1) % m];
        n[0] += (p[1] - q[1]) * (p[2] + q[2]);
        n[1] += (p[2] - q[2]) * (p[0] + q[0]);
        n[2] += (p[0] - q[0]) * (p[1] + q[1]);
    }
    return n;
}

// `sign( cross(r1-r0, r[n-1]-r0) · Newell(ring) )` — "is the corner AT RING
// INDEX 0 convex with respect to the ring's OWN normal". The zero is a real
// third class (a corner whose triangle has zero area), and keeping it apart
// from +1 is what separates three answer families on a ring that carries both
// a collinear and a reflex corner. `mergeZero` folds it into +1 — the coarser
// reading a second measured family answers to.
private int corner0Sign(double[3][] ring, bool mergeZero) {
    immutable n = ring.length;
    if (n < 3) return 0;
    auto r0 = ring[0], r1 = ring[1 % n], rl = ring[n - 1];
    double[3] a = [r1[0]-r0[0], r1[1]-r0[1], r1[2]-r0[2]];
    double[3] b = [rl[0]-r0[0], rl[1]-r0[1], rl[2]-r0[2]];
    double[3] c = [a[1]*b[2] - a[2]*b[1],
                   a[2]*b[0] - a[0]*b[2],
                   a[0]*b[1] - a[1]*b[0]];
    auto nn = newellNormal(ring);
    double d = c[0]*nn[0] + c[1]*nn[1] + c[2]*nn[2];
    int s = (fabs(d) <= 1e-9) ? 0 : (d > 0 ? 1 : -1);
    if (mergeZero && s == 0) s = 1;
    return s;
}

// True iff every pair the FINE partition calls equal is also called equal by
// the COARSE one — i.e. the predicate's "these rotations MUST agree" claim
// survives the measurement.
private bool partitionRefines(string fine, string coarse) {
    if (fine.length != coarse.length) return false;
    foreach (i; 0 .. fine.length)
        foreach (j; i + 1 .. fine.length)
            if (fine[i] == fine[j] && coarse[i] != coarse[j]) return false;
    return true;
}

private size_t classCount(string pattern) {
    bool[char] seen;
    foreach (c; pattern) seen[c] = true;
    return seen.length;
}

// The base mesh a rotation's `input` loads, plus the rings of the faces its
// `select` step names. The ring ORDER is read from the load-mesh body — it is
// the whole subject here, so it must not come from a live query that has
// already normalised it away.
private void baseRingsOf(JSONValue input, string cn,
                         out double[3][] baseVerts, out double[3][][] baseFaces,
                         out double[3][][] selRings) {
    foreach (step; input.array) {
        if ("endpoint" in step && step["endpoint"].str == "load-mesh") {
            auto b = step["body"];
            foreach (v; b["vertices"].array) baseVerts ~= jvec3(v);
            foreach (f; b["faces"].array) {
                double[3][] ring;
                foreach (fi; f.array) ring ~= baseVerts[cast(size_t) fi.integer];
                baseFaces ~= ring;
            }
        }
    }
    assert(baseVerts.length, format("%s: rotation has no load-mesh step", cn));
    foreach (step; input.array) {
        if ("select" !in step) continue;
        auto sel = step["select"];
        if (sel["mode"].str != "polygons" || "coords" !in sel) continue;
        foreach (spec; sel["coords"].array) {
            double[3][] want;
            foreach (w; spec.array) want ~= jvec3(w);
            long hit = -1;
            foreach (i, ring; baseFaces) {
                if (ring.length != want.length) continue;
                auto used = new bool[](ring.length);
                bool ok = true;
                foreach (w; want) {
                    bool found = false;
                    foreach (k, p; ring)
                        if (!used[k] && dist2(p, w) <= COORD_EPS*COORD_EPS) {
                            used[k] = true; found = true; break;
                        }
                    if (!found) { ok = false; break; }
                }
                if (ok) { hit = cast(long) i; break; }
            }
            assert(hit >= 0, format("%s: selected polygon is not a face of the "
                                    ~ "loaded base mesh", cn));
            selRings ~= baseFaces[cast(size_t) hit];
        }
    }
}

/// Run an orbit-shaped known-divergence suite. See the block comment above
/// for what each assertion means. Schema (per case):
///   { "name": "...", "ledger_rows": [..], "channel": "vertices|faces|faces_any_winding",
///     "face_ring_start": "compared" | "ignored",   // task 1310: "compared"
///     //   adds the `face_tuples` channel below and requires its two patterns;
///     //   "ignored" keeps the three ring-SET channels and needs a note.
///     "kind": "reference_reads_the_ring|we_read_the_ring|both_read_the_ring|
///              capability_gap|neither_reads_the_ring",
///     "orbit": { "vibe3d":    {"vertices":"..","faces":"..",
///                              "faces_any_winding":"..","face_tuples":".."},
///                "reference": { ... same set ... } },
///     "sign_predicate": { "reading": "three|two", "classes": "010020",
///                         "relation_to_reference": "exact|refines|violated" },
///     "rotations": [ { "rot": 0, "input": [...], "op": [...],
///                      "vibe3d":    {"applied":bool,"counts":{..},
///                                    "vertices":[..],"faces":[[..],..]},
///                      "reference": { ... same shape ... } }, ... ] }
void runRingOrbitSuite(string fixtureJson) {
    auto fx      = parseJSON(fixtureJson);
    string suite = ("name" in fx) ? fx["name"].str : "<orbit-suite>";
    requireProvenance(fx, suite);
    double tolD  = ("tolerance" in fx) ? asDouble(fx["tolerance"]) : 1e-3;

    static immutable string[] kRingSetChannels =
        ["vertices", "faces", "faces_any_winding"];
    auto tally = RingStartTally(suite);
    scope (exit) ringStartSummary(tally);

    foreach (cs; fx["cases"].array) {
        string cn  = suite ~ "/" ~ (("name" in cs) ? cs["name"].str : "<case>");
        double tol = ("tolerance" in cs) ? asDouble(cs["tolerance"]) : tolD;
        string channel = cs["channel"].str;
        // Task 1310: an orbit case is ABOUT where a ring starts, so whether
        // its own comparison can see a ring start is not a detail. Declaring
        // "compared" adds the `face_tuples` channel to the patterns below;
        // "ignored" keeps the three ring-SET channels only and must say why.
        auto rs = ringStartDeclOf(fx, cs, cn);
        string[] kChannels = kRingSetChannels.dup;
        if (rs.compared) kChannels ~= "face_tuples";

        OrbitAnswer[] ours, refs;
        double[3][][] frozenMine;  // our own recorded rings for rotation 0
        double[3][][] predRings;   // the selected ring of each rotation
        bool weApplyAll = true, refAppliesAll = true;

        foreach (ri, rot; cs["rotations"].array) {
            string rn = format("%s r%d", cn,
                               ("rot" in rot) ? rot["rot"].integer : cast(long) ri);

            double[3][] baseVerts; double[3][][] baseFaces, selRings;
            baseRingsOf(rot["input"], rn, baseVerts, baseFaces, selRings);
            if (selRings.length) predRings ~= selRings[0];

            foreach (i, step; rot["input"].array) runStep(step, rn, "input", i);
            // A case must actually RUN something. Two of these cases record
            // that our op refuses, and for those an empty `op` list would
            // leave exactly the mesh a refusal leaves — so the emptiness is
            // checked here, and each op step additionally pins the status it
            // must come back with (see postStep's `expectStatus`).
            assert(rot["op"].array.length > 0,
                format("%s: rotation has no op steps — a case with nothing to "
                       ~ "run measures nothing", rn));
            foreach (i, step; rot["op"].array)    runStep(step, rn, "op", i);

            auto got = OrbitAnswer(readVertices(), readFaceRings());

            // ---- (1) this rotation's own output, verbatim -----------------
            auto mine = rot["vibe3d"];
            if ("counts" in mine) {
                auto c = readCounts();
                auto ec = mine["counts"];
                assert(ec["verts"].integer == c[0],
                    format("%s: vertex count expected %d, got %d",
                           rn, ec["verts"].integer, c[0]));
                assert(ec["polys"].integer == c[2],
                    format("%s: face count expected %d, got %d",
                           rn, ec["polys"].integer, c[2]));
                if (c[1] >= 0)
                    assert(ec["edges"].integer == c[1],
                        format("%s: edge count expected %d, got %d",
                               rn, ec["edges"].integer, c[1]));
            }
            double[3][] wantV;
            foreach (v; mine["vertices"].array) wantV ~= jvec3(v);
            assert(centroidSetEq(got.verts, wantV, tol),
                format("%s: vibe3d no longer produces its recorded vertex set "
                       ~ "— this fixture records a KNOWN DIVERGENCE; if the "
                       ~ "behaviour changed deliberately, re-measure and "
                       ~ "update it", rn));
            double[3][][] wantF;
            foreach (f; mine["faces"].array) {
                double[3][] ring;
                foreach (v; f.array) ring ~= jvec3(v);
                wantF ~= ring;
            }
            if (ri == 0) frozenMine = wantF;
            assert(faceSetsEqual(got.faces, wantF, true, tol),
                format("%s: vibe3d no longer produces its recorded face rings "
                       ~ "(winding included)", rn));

            // ---- (2) did our op apply at all — re-derived, not trusted ----
            bool applied = !(centroidSetEq(got.verts, baseVerts, tol)
                             && faceSetsEqual(got.faces, baseFaces, true, tol));
            assert(applied == (mine["applied"].type == JSONType.true_),
                format("%s: fixture says our op %s here, but the mesh %s the "
                       ~ "one the input loaded", rn,
                       mine["applied"].type == JSONType.true_ ? "APPLIES" : "does NOT apply",
                       applied ? "differs from" : "is identical to"));
            if (!applied) weApplyAll = false;
            if (rot["reference"]["applied"].type != JSONType.true_) refAppliesAll = false;

            ours ~= got;
            OrbitAnswer rf;
            foreach (v; rot["reference"]["vertices"].array) rf.verts ~= jvec3(v);
            foreach (f; rot["reference"]["faces"].array) {
                double[3][] ring;
                foreach (v; f.array) ring ~= jvec3(v);
                rf.faces ~= ring;
            }
            refs ~= rf;

            // ---- the CROSS-ENGINE claim, per rotation --------------------
            // Without this a case whose two orbit patterns happen to agree
            // asserts nothing about the reference at all — and two of these
            // cases are exactly that shape (both sides ring-invariant, the
            // question being whether they land in the same place).
            if ("matches_reference" in mine) {
                auto mr = mine["matches_reference"];
                bool vEq = centroidSetEq(got.verts, rf.verts, tol);
                bool fEq = faceSetsEqual(got.faces, rf.faces, false, tol);
                assert(vEq == (mr["vertices"].type == JSONType.true_),
                    format("%s: our vertices %s the reference's, the fixture "
                           ~ "says they %s", rn,
                           vEq ? "now MATCH" : "no longer match",
                           mr["vertices"].type == JSONType.true_ ? "match" : "differ"));
                assert(fEq == (mr["faces"].type == JSONType.true_),
                    format("%s: our face rings %s the reference's, the fixture "
                           ~ "says they %s", rn,
                           fEq ? "now MATCH" : "no longer match",
                           mr["faces"].type == JSONType.true_ ? "match" : "differ"));
            }
        }

        // Accrued on the pair this suite actually PINS: our own frozen
        // rotation-0 record against the live run. (The cross-engine tuple
        // question is not a ring count here -- it is the `face_tuples`
        // ORBIT PATTERN asserted below, on both sides.)
        if (ours.length && frozenMine.length)
            ringStartAccrue(tally, rs, frozenMine, ours[0].faces, tol);

        // ---- (3)+(4) the patterns, both sides, every channel --------------
        string[string] oursPat, refPat;
        foreach (ch; kChannels) {
            oursPat[ch] = orbitPattern(ours, ch, tol);
            refPat[ch]  = orbitPattern(refs, ch, tol);
            assert(ch in cs["orbit"]["vibe3d"] && ch in cs["orbit"]["reference"],
                format("%s: the '%s' channel is being computed but the case "
                       ~ "declares no orbit pattern for it on both sides", cn, ch));
            assert(oursPat[ch] == cs["orbit"]["vibe3d"][ch].str,
                format("%s: our orbit pattern in the '%s' channel is now %s, "
                       ~ "the fixture froze %s. The ring-order behaviour "
                       ~ "CHANGED — re-measure and update the fixture; if we "
                       ~ "now match the reference, replace this case with a "
                       ~ "parity one.", cn, ch, oursPat[ch],
                       cs["orbit"]["vibe3d"][ch].str));
            assert(refPat[ch] == cs["orbit"]["reference"][ch].str,
                format("%s: the frozen reference blocks give pattern %s in the "
                       ~ "'%s' channel, but the fixture declares %s — the "
                       ~ "record no longer describes its own data",
                       cn, refPat[ch], ch, cs["orbit"]["reference"][ch].str));
        }

        // ---- (5) who reads the ring, re-derived --------------------------
        immutable on = classCount(oursPat[channel]);
        immutable rnn = classCount(refPat[channel]);
        string kind;
        if (!weApplyAll && refAppliesAll && on == 1 && rnn == 1) kind = "capability_gap";
        else if (on > 1 && rnn > 1)                              kind = "both_read_the_ring";
        else if (rnn > 1)                                        kind = "reference_reads_the_ring";
        else if (on > 1)                                         kind = "we_read_the_ring";
        else                                                     kind = "neither_reads_the_ring";
        assert(kind == cs["kind"].str,
            format("%s: the data now classifies as '%s', the fixture says "
                   ~ "'%s' (ours %s / reference %s in the '%s' channel; we "
                   ~ "apply everywhere: %s)", cn, kind, cs["kind"].str,
                   oursPat[channel], refPat[channel], channel, weApplyAll));

        // A capability gap is NOT a ring-order law and must not be filed as
        // one: both sides are invariant, and what differs is that our op does
        // not run at all.
        if (kind == "capability_gap")
            assert(!weApplyAll && refAppliesAll,
                format("%s: declared a capability gap, but the applied flags "
                       ~ "do not say so", cn));

        // ---- (6) the sign predicate, recomputed from the base rings ------
        if ("sign_predicate" in cs) {
            auto sp = cs["sign_predicate"];
            bool mergeZero = sp["reading"].str == "two";
            assert(predRings.length == cs["rotations"].array.length,
                format("%s: sign predicate needs one selected polygon ring per "
                       ~ "rotation, got %d of %d", cn, predRings.length,
                       cs["rotations"].array.length));
            int[] keys;
            foreach (ring; predRings) keys ~= corner0Sign(ring, mergeZero);
            int[] seen; string pp;
            foreach (k; keys) {
                long hit = -1;
                foreach (i, s; seen) if (s == k) { hit = cast(long) i; break; }
                if (hit < 0) { seen ~= k; hit = cast(long) seen.length - 1; }
                pp ~= format("%d", hit);
            }
            assert(pp == sp["classes"].str,
                format("%s: the sign predicate over this orbit's OWN base "
                       ~ "rings gives %s, the fixture declares %s",
                       cn, pp, sp["classes"].str));
            string rel = (pp == refPat["faces"]) ? "exact"
                       : (partitionRefines(pp, refPat["faces"]) ? "refines"
                                                                      : "violated");
            assert(rel == sp["relation_to_reference"].str,
                format("%s: the predicate now '%s' the reference's pattern %s "
                       ~ "(predicate %s), the fixture declares '%s'",
                       cn, rel, refPat["faces"], pp,
                       sp["relation_to_reference"].str));
        }
    }
}

// ===========================================================================
// COMMAND-LEVEL divergences (task 1130)
// ===========================================================================

/// One engine-neutral observation of "what a command did".  Every field is
/// keyed on COORDINATES or counts, never on indices — vertex/edge/face order
/// is not a promise across engines, and half of these cases exist precisely
/// because one engine renumbers where the other refuses.
private struct CmdObs {
    bool[]        applied;            // one entry per `op` step, in order
    long[3]       counts;             // verts, edges, faces
    double[3][]   verts;
    double[3][2][] edges;             // endpoint pairs, canonical order
    // Faces as RINGS OF COORDINATES, compared up to rotation but never
    // reflection — task 1140's channel, reused verbatim rather than
    // re-implemented. A centroid multiset (what this field used to hold) is
    // blind to winding AND to ring ORDER, and ring order is the entire content
    // of at least one case below (a bow-tie click order builds the same four
    // points into a different polygon).
    double[3][][]  faceRings;
    string        selMode;
    double[3][]   selVerts;
    double[3][2][] selEdges;
    double[3][]   selPolys;           // face centroids of the selection
    long          materialsChanged;   // faces whose material differs from pre-op
}

private bool vecLess(double[3] a, double[3] b) {
    foreach (k; 0 .. 3) {
        if (a[k] < b[k] - COORD_EPS) return true;
        if (a[k] > b[k] + COORD_EPS) return false;
    }
    return false;
}

// Endpoint pairs are undirected: canonicalise so (a,b) and (b,a) compare equal.
private double[3][2] canonPair(double[3] a, double[3] b) {
    return vecLess(b, a) ? [b, a] : [a, b];
}

private bool pairNear(double[3][2] p, double[3][2] q, double tol) {
    return dist2(p[0], q[0]) <= tol*tol && dist2(p[1], q[1]) <= tol*tol;
}

// Multiset difference: the members of `a` that find no UNUSED partner in `b`.
// Greedy consumption matters — several of these cases legitimately produce
// COINCIDENT vertices (a set-position that lands two corners on one point), and a
// plain "is there any match" test would silently forgive a lost duplicate.
private double[3][] vecOnlyIn(double[3][] a, double[3][] b, double tol) {
    auto used = new bool[](b.length);
    double[3][] outv;
    foreach (x; a) {
        bool hit = false;
        foreach (i, y; b)
            if (!used[i] && dist2(x, y) <= tol*tol) { used[i] = true; hit = true; break; }
        if (!hit) outv ~= x;
    }
    return outv;
}

private double[3][2][] pairOnlyIn(double[3][2][] a, double[3][2][] b, double tol) {
    auto used = new bool[](b.length);
    double[3][2][] outv;
    foreach (x; a) {
        bool hit = false;
        foreach (i, y; b)
            if (!used[i] && pairNear(x, y, tol)) { used[i] = true; hit = true; break; }
        if (!hit) outv ~= x;
    }
    return outv;
}

private double[3][] jVecList(JSONValue v) {
    double[3][] outv;
    foreach (e; v.array) outv ~= jvec3(e);
    return outv;
}

// A fixture's `faces` block is a LIST of rings; `jring` (task 1140) reads one.
private double[3][][] jRingList(JSONValue v) {
    double[3][][] outv;
    foreach (e; v.array) outv ~= jring(e);
    return outv;
}

private double[3][2][] jPairList(JSONValue v) {
    double[3][2][] outv;
    foreach (e; v.array) {
        auto pr = e.array;
        outv ~= canonPair(jvec3(pr[0]), jvec3(pr[1]));
    }
    return outv;
}

// Assert two coordinate multisets are equal, both directions, with a message
// that names which side lost what.
private void sameVecSet(string cn, string what, double[3][] got,
                        double[3][] want, double tol, string hint) {
    auto missing = vecOnlyIn(want, got, tol);
    auto extra   = vecOnlyIn(got, want, tol);
    assert(missing.length == 0 && extra.length == 0,
        format("%s: %s differs from the frozen record — missing %s, extra %s. %s",
               cn, what, missing, extra, hint));
}

private void sameRingSet(string cn, string what, double[3][][] got,
                         double[3][][] want, double tol, string hint,
                         bool exact = false) {
    // `exact` is task 1310's ring-start reading: same matcher, same call
    // sites, one declared flag deciding whether a ring may match a rotation
    // of itself. Defaulted so no other caller changes.
    auto missing = ringsMissingBy(want, got, tol, exact);
    auto extra   = ringsMissingBy(got, want, tol, exact);
    string show(double[3][][] rs) {
        string o;
        foreach (i, r; rs) { if (i) o ~= ", "; o ~= ringStr(r); }
        return "[" ~ o ~ "]";
    }
    assert(missing.length == 0 && extra.length == 0,
        format("%s: %s differs from the frozen record — missing %s, extra %s. %s",
               cn, what, show(missing), show(extra), hint));
}

private void samePairSet(string cn, string what, double[3][2][] got,
                         double[3][2][] want, double tol, string hint) {
    auto missing = pairOnlyIn(want, got, tol);
    auto extra   = pairOnlyIn(got, want, tol);
    assert(missing.length == 0 && extra.length == 0,
        format("%s: %s differs from the frozen record — missing %s, extra %s. %s",
               cn, what, missing, extra, hint));
}

// Read the live faceMaterial array (absent => empty, which simply makes the
// materials dimension inert for that case rather than failing it).
private long[] readFaceMaterials() {
    auto m = parseJSON(cast(string) get(BASE ~ "/api/model"));
    long[] outv;
    if ("faceMaterial" in m)
        foreach (e; m["faceMaterial"].array) outv ~= e.integer;
    return outv;
}

// Observe the live engine after the op: geometry, selection, materials.
private CmdObs observeCmd(bool[] applied, long[] preMaterials) {
    CmdObs o;
    o.applied = applied;

    auto model = parseJSON(cast(string) get(BASE ~ "/api/model"));
    auto V = model["vertices"].array;
    double[3] vpos(long i) { return jvec3(V[cast(size_t) i]); }

    o.counts = [model["vertexCount"].integer,
                ("edgeCount" in model) ? model["edgeCount"].integer : -1,
                model["faceCount"].integer];
    foreach (v; V) o.verts ~= jvec3(v);
    foreach (e; model["edges"].array) {
        auto ee = e.array;
        o.edges ~= canonPair(vpos(ee[0].integer), vpos(ee[1].integer));
    }
    double[3] centroid(JSONValue f) {
        auto fv = f.array;
        double[3] c = [0, 0, 0];
        foreach (fi; fv) {
            auto p = vpos(fi.integer);
            c[0] += p[0]; c[1] += p[1]; c[2] += p[2];
        }
        double n = cast(double) fv.length;
        if (n > 0) { c[0] /= n; c[1] /= n; c[2] /= n; }
        return c;
    }
    o.faceRings = readFaceRings();

    auto sel = parseJSON(cast(string) get(BASE ~ "/api/selection"));
    o.selMode = ("mode" in sel) ? sel["mode"].str : "";
    foreach (si; sel["selectedVertices"].array) o.selVerts ~= vpos(si.integer);
    foreach (si; sel["selectedEdges"].array) {
        auto ee = model["edges"].array[cast(size_t) si.integer].array;
        o.selEdges ~= canonPair(vpos(ee[0].integer), vpos(ee[1].integer));
    }
    foreach (si; sel["selectedFaces"].array)
        o.selPolys ~= centroid(model["faces"].array[cast(size_t) si.integer]);

    // Materials are compared as a COUNT OF CHANGED FACES, not by id: material
    // identity is not shared across engines (one names them, we number them),
    // but "this command retagged N faces" is the same fact on both sides.
    auto postMats = readFaceMaterials();
    long changed = 0;
    foreach (i, m2; postMats)
        if (i >= preMaterials.length || preMaterials[i] != m2) ++changed;
    o.materialsChanged = changed;
    return o;
}

/// runCommandDivergenceSuite — the COMMAND-level counterpart of
/// runKnownDivergenceSuite (above), and it exists because the divergences it
/// freezes do not live in the vertex positions that runner compares.
///
/// A command-level disagreement shows up as: the reference APPLIES where we
/// refuse (or the reverse); the two engines leave a DIFFERENT SELECTION behind;
/// the topology moves while every vertex stays exactly put (an edge spin is the
/// pure case — same six coordinates, one different diagonal); or the command
/// surface itself disagrees about which argument values are legal. Feed any of
/// those to a vertex-set comparison and you get an empty difference, i.e. a
/// green test that has measured nothing.
///
/// Same three-part discipline as runKnownDivergenceSuite, over the dimensions a
/// command divergence actually inhabits:
///   1. our live output still equals `vibe3d_current`  — a regression pin;
///   2. `reference` is the frozen measurement, untouched;
///   3. the gap RECOMPUTED between (1) and (2) is EXACTLY the declared
///      `divergence` — the load-bearing one. Narrow the gap and this reddens,
///      which is the prompt to re-measure, and to retire the case into a parity
///      fixture once it closes completely.
/// Plus a fourth that only a multi-dimensional gap needs:
///   4. a non-control case must declare a NON-EMPTY gap. A divergence fixture
///      whose every dimension agrees is a parity test wearing the wrong hat,
///      and it would pass forever without asserting anything about the
///      disagreement it claims to record.
///
/// A case may also declare a CONTROL — a cell that is in the fixture because
/// what AGREES there is what makes the neighbouring divergence readable. Spin
/// the same edge twice versus re-select the product and spin again: the second
/// converges GEOMETRICALLY, which is how we know the first is about SELECTION
/// and not about the spin arithmetic. So a control is per-DIMENSION, not
/// per-case — that pair converges in the geometry and still disagrees in the
/// selection, and a whole-case control could not say so:
///   "control": true                      — every dimension must agree
///   "control": ["counts","vertices","edges","faces","applied"]
///                                        — THESE must agree; the case is still
///                                          a divergence somewhere else, and
///                                          must still declare one — UNLESS the
///                                          list names every measured dimension,
///                                          which is how a case whose gap has
///                                          been CLOSED (a ported law) declares
///                                          an EMPTY gap and keeps asserting it
///                                          per-dimension. Prefer that over
///                                          `control: true`, which cannot tell
///                                          "they agreed" from "nobody looked".
/// Dimension names: applied, counts, materials, vertices, edges, faces,
/// selection_mode, sel_vertices, sel_edges, sel_polygons. A control dimension
/// that acquires a gap reddens with its own message: that is a finding, because
/// the control is load-bearing for reading the divergence beside it. A control
/// dimension that is never MEASURED (absent from either block) reddens too, and
/// for a different reason — an unmeasured control is green forever and is the
/// exact shape of an assertion that has quietly gone inert.
///
/// `op` steps are run WITHOUT the usual abort-on-error: a refusal is the
/// measurement here, not a broken fixture. Their outcomes land in `applied`,
/// one bool per step, in order.
///
/// Schema:
///   { "name": "...", "provenance": {...}, "tolerance": 1e-4,
///     "cases": [ {
///       "name": "...",
///       "input": [ ...step vocabulary: reset / load-mesh / select... ],
///       "op":    [ {"endpoint":"command","body":{...}}, ... ],
///       "reference":      <observation>,
///       "vibe3d_current": <observation>,
///       "divergence": {
///          "applied":            {"reference":[true,true], "vibe3d":[true,false]},
///          "counts_delta":       {"verts":0,"edges":1,"faces":0},   // ref - ours
///          "materials_changed_delta": 2,   // see the note on this channel below
///          "selection_mode":     {"reference":"edges","vibe3d":"vertices"},
///          "vertices_only_in_reference": [[x,y,z],...],
///          "vertices_only_in_vibe3d":    [...],
///          "edges_only_in_reference":    [[[x,y,z],[x,y,z]],...],
///          "edges_only_in_vibe3d":       [...],
///          "faces_only_in_reference":    [ [[x,y,z],...], ... ],  // rings
///          "faces_only_in_vibe3d":       [...],
///          "sel_vertices_only_in_reference": [...], "sel_vertices_only_in_vibe3d": [...],
///          "sel_edges_only_in_reference":    [...], "sel_edges_only_in_vibe3d":    [...],
///          "sel_polygons_only_in_reference": [...], "sel_polygons_only_in_vibe3d": [...]
///       },
///       "control": false,
///       "face_ring_start": "compared" | "ignored",
///       "face_ring_start_note": "..."   // required when "ignored"; task 1310
///     } ] }
///
/// An `<observation>` carries any of:
///   "applied": [bool,...], "counts": {"verts":V,"edges":E,"faces":F},
///   "vertices": [[x,y,z],...], "edges": [[[x,y,z],[x,y,z]],...],
///   "faces": [ [[x,y,z],...], ... ]                 (rings, task 1140's
///                                                    rotation-not-reflection
///                                                    comparison),
///   "selection": {"mode":"edges","vertices":[...],"edges":[...],"polygons":[...]},
///   "materials_changed": N
/// A dimension absent from EITHER block is not diffed — "we did not measure
/// that here" is a real state and must not be confused with "they agreed".
///
/// On `materials_changed` vs task 1140's `material_groups`: they are NOT two
/// implementations of one comparison and must not be folded together. 1140 asks
/// "do the two engines put the same faces in the same GROUP" — the partition,
/// the only material fact the two namespaces share. This channel asks "did the
/// command RETAG anything at all", and it exists because there is a case where
/// the partition is identical on both sides and the divergence is total: fire
/// set-material with an empty selection and the reference paints both faces of
/// a two-face plate while we do nothing. One group of two, either way. The
/// partition sees parity; the retag count sees 2 against 0.
/// `vibe3d_current` may additionally carry "error_contains": [null, "..."] —
/// a per-op-step substring assertion on OUR OWN error text (a parse rejection
/// and a kernel refusal are both "did not apply" to a count, and for the
/// command-surface cases the difference between them IS the finding).
void runCommandDivergenceSuite(string fixtureJson) {
    auto fx      = parseJSON(fixtureJson);
    string suite = ("name" in fx) ? fx["name"].str : "<command-divergence-suite>";
    requireProvenance(fx, suite);
    double tolD  = ("tolerance" in fx) ? asDouble(fx["tolerance"]) : 1e-4;
    auto tally = RingStartTally(suite);
    scope (exit) ringStartSummary(tally);

    foreach (cs; fx["cases"].array) {
        string cn  = suite ~ "/" ~ (("name" in cs) ? cs["name"].str : "<case>");
        double tol = ("tolerance" in cs) ? asDouble(cs["tolerance"]) : tolD;
        // `control` is either `true` (every dimension must agree) or the LIST of
        // dimensions that must. See the schema note above for why per-dimension.
        bool   controlAll = ("control" in cs) && cs["control"].type == JSONType.true_;
        bool[string] controlDim;
        if ("control" in cs && cs["control"].type == JSONType.array)
            foreach (d; cs["control"].array) controlDim[d.str] = true;

        foreach (i, step; cs["input"].array) runStep(step, cn, "input", i);

        auto preMaterials = readFaceMaterials();

        // ---- op: run it, RECORD the outcome, never abort on a refusal ----
        bool[]   applied;
        string[] messages;
        foreach (i, step; cs["op"].array) {
            if ("endpoint" in step && step["endpoint"].str == "command") {
                string reqBody = ("argstring" in step) ? step["argstring"].str
                                                       : step["body"].toString;
                auto resp = cast(string) post(BASE ~ "/api/command", reqBody);
                bool ok = false;
                string msg = resp;
                if (resp.length && resp[0] == '{') {
                    auto j = parseJSON(resp);
                    ok = ("status" in j) && j["status"].str == "ok";
                    if ("message" in j) msg = j["message"].str;
                    else if ("error" in j) msg = j["error"].str;
                    else if (ok) msg = "";
                }
                applied  ~= ok;
                messages ~= msg;
            } else {
                runStep(step, cn, "op", i);
                applied  ~= true;
                messages ~= "";
            }
        }

        auto live = observeCmd(applied, preMaterials);
        auto cur  = cs["vibe3d_current"];
        auto refB = cs["reference"];

        enum string REPIN =
            "This fixture records a KNOWN COMMAND DIVERGENCE; if you changed "
            ~ "the behaviour deliberately, re-measure BOTH sides and update it "
            ~ "— and if the gap closed entirely, delete the case and add a "
            ~ "parity one.";

        // -------- (1) our own output, verbatim ---------------------------
        if ("applied" in cur) {
            auto wantA = cur["applied"].array;
            assert(wantA.length == live.applied.length,
                format("%s: recorded %d op outcomes, ran %d",
                       cn, wantA.length, live.applied.length));
            foreach (i, w; wantA) {
                bool wb = w.type == JSONType.true_;
                assert(wb == live.applied[i],
                    format("%s: op step %d applied=%s, the fixture records %s "
                           ~ "(engine said: %s). %s",
                           cn, i, live.applied[i], wb, messages[i], REPIN));
            }
        }
        if ("error_contains" in cur) {
            foreach (i, w; cur["error_contains"].array) {
                if (w.type == JSONType.null_) continue;
                assert(i < messages.length,
                    format("%s: error_contains has %d entries, ran %d op steps",
                           cn, cur["error_contains"].array.length, messages.length));
                import std.algorithm : canFind;
                assert(messages[i].canFind(w.str),
                    format("%s: op step %d message %s does not contain '%s'. %s",
                           cn, i, messages[i], w.str, REPIN));
            }
        }
        if ("counts" in cur) assertCounts(cn, "vibe3d_current", cur["counts"], live.counts);
        if ("vertices" in cur)
            sameVecSet(cn, "our vertex set", live.verts, jVecList(cur["vertices"]), tol, REPIN);
        if ("edges" in cur)
            samePairSet(cn, "our edge set", live.edges, jPairList(cur["edges"]), tol, REPIN);
        // Task 1310: this case compares face RINGS, so it must declare
        // whether that comparison covers where each ring starts. The one
        // declaration governs both the regression pin below and the
        // recomputed reference gap further down.
        auto ringStart = ("faces" in cur) ? ringStartDeclOf(fx, cs, cn)
                                          : RingStartDecl(false, "n/a");
        if ("faces" in cur)
            sameRingSet(cn, "our face rings", live.faceRings,
                        jRingList(cur["faces"]), tol, REPIN, ringStart.compared);
        if ("materials_changed" in cur)
            assert(live.materialsChanged == cur["materials_changed"].integer,
                format("%s: we retagged %d faces, the fixture records %d. %s",
                       cn, live.materialsChanged, cur["materials_changed"].integer, REPIN));
        if ("selection" in cur) {
            auto s = cur["selection"];
            if ("mode" in s)
                assert(live.selMode == s["mode"].str,
                    format("%s: our selection mode is '%s', the fixture records '%s'. %s",
                           cn, live.selMode, s["mode"].str, REPIN));
            if ("vertices" in s)
                sameVecSet(cn, "our selected vertices", live.selVerts,
                           jVecList(s["vertices"]), tol, REPIN);
            if ("edges" in s)
                samePairSet(cn, "our selected edges", live.selEdges,
                            jPairList(s["edges"]), tol, REPIN);
            if ("polygons" in s)
                sameVecSet(cn, "our selected polygons", live.selPolys,
                           jVecList(s["polygons"]), tol, REPIN);
        }

        // -------- (3) the gap, RECOMPUTED from live vs the frozen ref -----
        auto dv = ("divergence" in cs) ? cs["divergence"] : JSONValue(cast(JSONValue[string]) null);
        bool anyGap = false;
        bool[string] gapIn;
        // A dimension is MEASURED only when both blocks carry it. Recording that
        // separately from "it has a gap" is what stops a control from passing
        // because nobody looked: `control: ["counts"]` on a case whose reference
        // block has no counts would otherwise be silently, permanently green.
        bool[string] measuredDim;
        void mark(string dim, bool gap) {
            measuredDim[dim] = true;
            if (!gap) return;
            anyGap = true;
            gapIn[dim] = true;
        }

        enum string MOVED =
            "The DIVERGENCE MOVED. Re-measure the reference and update this "
            ~ "fixture; if it closed completely, replace the case with a parity one.";

        void wantVecs(string dim, string key, double[3][] have) {
            auto want = (key in dv) ? jVecList(dv[key]) : (double[3][]).init;
            mark(dim, have.length > 0);
            sameVecSet(cn, "divergence." ~ key, have, want, tol, MOVED);
        }
        void wantRings(string dim, string key, double[3][][] have) {
            auto want = (key in dv) ? jRingList(dv[key]) : (double[3][][]).init;
            mark(dim, have.length > 0);
            sameRingSet(cn, "divergence." ~ key, have, want, tol, MOVED, ringStart.compared);
        }
        void wantPairs(string dim, string key, double[3][2][] have) {
            auto want = (key in dv) ? jPairList(dv[key]) : (double[3][2][]).init;
            mark(dim, have.length > 0);
            samePairSet(cn, "divergence." ~ key, have, want, tol, MOVED);
        }

        if ("applied" in refB && "applied" in cur) {
            auto refA = refB["applied"].array;
            bool differs = refA.length != live.applied.length;
            if (!differs)
                foreach (i, w; refA)
                    if ((w.type == JSONType.true_) != live.applied[i]) differs = true;
            mark("applied", differs);
            assert(("applied" in dv) !is null || !differs,
                format("%s: the two engines disagree about WHETHER the command "
                       ~ "applied, but the fixture declares no divergence.applied. %s",
                       cn, MOVED));
            if ("applied" in dv) {
                auto da = dv["applied"];
                foreach (i, w; da["reference"].array)
                    assert((w.type == JSONType.true_) == (refA[i].type == JSONType.true_),
                        format("%s: divergence.applied.reference[%d] contradicts "
                               ~ "the frozen reference block", cn, i));
                foreach (i, w; da["vibe3d"].array)
                    assert((w.type == JSONType.true_) == live.applied[i],
                        format("%s: divergence.applied.vibe3d[%d] says %s, we did %s. %s",
                               cn, i, w.type == JSONType.true_, live.applied[i], MOVED));
            }
        }

        if ("counts" in refB && "counts" in cur) {
            auto rc = refB["counts"];
            string[3] keys = ["verts", "edges", "faces"];
            foreach (k, key; keys) {
                if ((key in rc) is null) continue;
                if (live.counts[k] < 0) continue;
                long delta = rc[key].integer - live.counts[k];
                mark("counts", delta != 0);
                long declared = 0;
                if ("counts_delta" in dv && (key in dv["counts_delta"]))
                    declared = dv["counts_delta"][key].integer;
                assert(delta == declared,
                    format("%s: %s delta is now %d (reference %d, ours %d), the "
                           ~ "fixture declares %d. %s",
                           cn, key, delta, rc[key].integer, live.counts[k], declared, MOVED));
            }
        }

        if ("materials_changed" in refB && "materials_changed" in cur) {
            long delta = refB["materials_changed"].integer - live.materialsChanged;
            mark("materials", delta != 0);
            long declared = ("materials_changed_delta" in dv)
                          ? dv["materials_changed_delta"].integer : 0;
            assert(delta == declared,
                format("%s: materials-changed delta is now %d, the fixture "
                       ~ "declares %d. %s", cn, delta, declared, MOVED));
        }

        if ("vertices" in refB && "vertices" in cur) {
            auto rv = jVecList(refB["vertices"]);
            wantVecs("vertices", "vertices_only_in_reference", vecOnlyIn(rv, live.verts, tol));
            wantVecs("vertices", "vertices_only_in_vibe3d",    vecOnlyIn(live.verts, rv, tol));
        }
        if ("edges" in refB && "edges" in cur) {
            auto re = jPairList(refB["edges"]);
            wantPairs("edges", "edges_only_in_reference", pairOnlyIn(re, live.edges, tol));
            wantPairs("edges", "edges_only_in_vibe3d",    pairOnlyIn(live.edges, re, tol));
        }
        if ("faces" in refB && "faces" in cur) {
            auto rf = jRingList(refB["faces"]);
            wantRings("faces", "faces_only_in_reference",
                      ringsMissingBy(rf, live.faceRings, tol, ringStart.compared));
            wantRings("faces", "faces_only_in_vibe3d",
                      ringsMissingBy(live.faceRings, rf, tol, ringStart.compared));
            ringStartAccrue(tally, ringStart, rf, live.faceRings, tol);
        } else if ("faces" in cur) {
            // No frozen reference geometry for this cell -- the face channel
            // here is a pin on OUR OWN recorded output and nothing more. It
            // still declares its ring-start reading, and the tally still says
            // how many rings it covered, so the log does not read as a
            // cross-engine claim.
            ringStartAccrue(tally, ringStart, jRingList(cur["faces"]), live.faceRings, tol);
        }

        if ("selection" in refB && "selection" in cur) {
            auto rs = refB["selection"], vs = cur["selection"];
            if ("mode" in rs && "mode" in vs) {
                bool differs = rs["mode"].str != live.selMode;
                mark("selection_mode", differs);
                if ("selection_mode" in dv) {
                    assert(dv["selection_mode"]["reference"].str == rs["mode"].str,
                        format("%s: divergence.selection_mode.reference contradicts "
                               ~ "the frozen reference block", cn));
                    assert(dv["selection_mode"]["vibe3d"].str == live.selMode,
                        format("%s: divergence.selection_mode.vibe3d says '%s', "
                               ~ "ours is '%s'. %s",
                               cn, dv["selection_mode"]["vibe3d"].str, live.selMode, MOVED));
                } else assert(!differs,
                    format("%s: selection modes disagree ('%s' vs '%s') but the "
                           ~ "fixture declares no divergence.selection_mode. %s",
                           cn, rs["mode"].str, live.selMode, MOVED));
            }
            if ("vertices" in rs && "vertices" in vs) {
                auto r = jVecList(rs["vertices"]);
                wantVecs("sel_vertices", "sel_vertices_only_in_reference", vecOnlyIn(r, live.selVerts, tol));
                wantVecs("sel_vertices", "sel_vertices_only_in_vibe3d",    vecOnlyIn(live.selVerts, r, tol));
            }
            if ("edges" in rs && "edges" in vs) {
                auto r = jPairList(rs["edges"]);
                wantPairs("sel_edges", "sel_edges_only_in_reference", pairOnlyIn(r, live.selEdges, tol));
                wantPairs("sel_edges", "sel_edges_only_in_vibe3d",    pairOnlyIn(live.selEdges, r, tol));
            }
            if ("polygons" in rs && "polygons" in vs) {
                auto r = jVecList(rs["polygons"]);
                wantVecs("sel_polygons", "sel_polygons_only_in_reference", vecOnlyIn(r, live.selPolys, tol));
                wantVecs("sel_polygons", "sel_polygons_only_in_vibe3d",    vecOnlyIn(live.selPolys, r, tol));
            }
        }

        // -------- (4) anti-vacuity / control ------------------------------
        enum string CTRL =
            "That is a finding, not a fixture chore: the control is what makes "
            ~ "the divergence beside it readable — this pair says the two "
            ~ "engines agree HERE, so the disagreement is somewhere else. "
            ~ "Measure what moved before touching this fixture.";
        if (controlAll)
            assert(!anyGap,
                format("%s: declared a whole-case CONTROL — a cell where the two "
                       ~ "engines agree in every dimension — but a divergence "
                       ~ "has appeared in it. %s", cn, CTRL));
        foreach (d, _; controlDim) {
            // Order matters: "never measured" is a different (and worse) fault
            // than "measured and now disagrees", so say which one it is.
            assert((d in measuredDim) !is null,
                format("%s: dimension '%s' is declared a CONTROL but is never "
                       ~ "MEASURED here — one of the two blocks does not carry "
                       ~ "it, so the control asserts nothing and would stay "
                       ~ "green through any change. Add the dimension to both "
                       ~ "`reference` and `vibe3d_current`, or drop the claim.",
                       cn, d));
            assert((d in gapIn) is null,
                format("%s: dimension '%s' is declared a CONTROL and has "
                       ~ "acquired a divergence. %s", cn, d, CTRL));
        }
        if (!controlAll) {
            // A per-dimension control list that names EVERY measured dimension
            // makes the same claim `control: true` makes — this cell agrees
            // everywhere — in the form that ALSO pins each dimension as
            // MEASURED, and is therefore strictly stronger. That is where a
            // PORTED law lands (task 1180): the gap closed in the selection
            // dimensions, and what has to stay asserted from then on is that it
            // stayed closed in each dimension it was ever open in — including
            // against someone quietly dropping `selection` from a block, which
            // `control: true` would sail straight through.
            //
            // Anything SHORT of full coverage is still a divergence fixture and
            // must still declare a gap: a partial control list is the "these
            // agree, the disagreement is elsewhere" shape, and "elsewhere" has
            // to exist. A case that measures nothing at all is not excused
            // either — `measuredDim.length > 0` keeps it on the old path.
            bool coversEveryMeasured = measuredDim.length > 0;
            foreach (d, _; measuredDim)
                if ((d in controlDim) is null) coversEveryMeasured = false;
            if (!coversEveryMeasured)
                assert(anyGap,
                    format("%s: every measured dimension AGREES, so this case "
                           ~ "asserts nothing about the divergence it claims to "
                           ~ "record. Either the gap closed — in which case say "
                           ~ "so by declaring EVERY measured dimension a control "
                           ~ "(an empty gap asserted as strictly as a full one), "
                           ~ "or retire the case into a parity fixture — or the "
                           ~ "case never measured the dimension the gap lives "
                           ~ "in.", cn));
        }
    }
}
