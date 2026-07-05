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
        case "load-mesh": return BASE ~ "/api/load-mesh";
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
        // {"reset":true} → default cube; {"reset":true,"empty":true} → empty
        // scene (use before prim.cube so the built primitive is the ONLY
        // geometry — otherwise prim.cube APPENDS onto the reset cube and the
        // two coincide at shared corners, doubling those verts).
        bool empty = ("empty" in step) && step["empty"].type == JSONType.true_;
        post(BASE ~ "/api/reset" ~ (empty ? "?empty=true" : ""), "");
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
        // op (adds crossing verts / chord-splits faces via Mesh.cutByPlane).
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
        cmd(format("tool.attr mesh.sliceTool startX %g", s[0]), ctx);
        cmd(format("tool.attr mesh.sliceTool startY %g", s[1]), ctx);
        cmd(format("tool.attr mesh.sliceTool startZ %g", s[2]), ctx);
        cmd(format("tool.attr mesh.sliceTool endX %g", en[0]), ctx);
        cmd(format("tool.attr mesh.sliceTool endY %g", en[1]), ctx);
        cmd(format("tool.attr mesh.sliceTool endZ %g", en[2]), ctx);
        // Optional axis constraint (S3): `"axis": "free|x|y|z|custom"` locks the
        // cut-plane normal to a world axis (x/y/z), the custom `"vector"`
        // [x,y,z], or the drawn line ⟂ work plane (free = default). `vector` is
        // only consulted when axis == custom.
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
///                  "lerp_checks": [ {"a":[..],"b":[..],"t":0.3,"point":[..]} ]
///                } ] }
void runTopologyDiffSuite(string fixtureJson) {
    auto fx      = parseJSON(fixtureJson);
    string suite = ("name" in fx) ? fx["name"].str : "<topo-suite>";
    double tolD  = ("tolerance" in fx) ? asDouble(fx["tolerance"]) : 1e-4;
    foreach (cs; fx["cases"].array) {
        string cn  = suite ~ "/" ~ (("name" in cs) ? cs["name"].str : "<case>");
        double tol = ("tolerance" in cs) ? asDouble(cs["tolerance"]) : tolD;

        foreach (i, step; cs["input"].array) runStep(step, cn, "input", i);
        if ("expected_before" in cs)
            assertCounts(cn, "before", cs["expected_before"], readCounts());

        foreach (i, step; cs["op"].array) runStep(step, cn, "op", i);
        if ("expected_after" in cs)
            assertCounts(cn, "after", cs["expected_after"], readCounts());

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
