#!/usr/bin/env rdmd
// Apply a comparison case to a running vibe3d --test instance and dump the
// resulting geometry to JSON. Caller is responsible for vibe3d lifecycle
// (run.d does this).
//
// Usage: rdmd vibe3d_dump.d <case.json> <out.json> [--port N]
//
// Reads the case schema described in blender_dump.py. Edges are specified
// by endpoint coordinate pairs (matching Blender) and translated to vibe3d
// edge indices via /api/model.

import std.algorithm : map;
import std.array : array;
import std.conv : to;
import std.file : readText, write;
import std.json;
import std.math : abs, PI;
import std.net.curl;
import std.stdio;
import std.string : startsWith;
import std.format : format;

int port = 8080;

string url(string path) {
    return "http://localhost:" ~ port.to!string ~ path;
}

JSONValue postJson(string path, string body_) {
    return parseJSON(post(url(path), body_));
}

void resetMesh(string primitiveType) {
    string path = "/api/reset";
    if (primitiveType.length > 0 && primitiveType != "cube")
        path ~= "?type=" ~ primitiveType;
    post(url(path), "");
}

// Returns the vibe3d edge index whose endpoints match (v0, v1) in either
// order, with EPS=1e-4 tolerance. Throws on no match.
int findEdgeIndex(JSONValue model, double[3] v0, double[3] v1) {
    auto verts = model["vertices"].array;
    auto edges = model["edges"].array;

    bool vmatch(JSONValue v, double[3] target) {
        auto a = v.array;
        return abs(a[0].floating - target[0]) < 1e-4
            && abs(a[1].floating - target[1]) < 1e-4
            && abs(a[2].floating - target[2]) < 1e-4;
    }

    foreach (i, e; edges) {
        auto pair = e.array;
        long a = pair[0].integer, b = pair[1].integer;
        bool fwd = vmatch(verts[a], v0) && vmatch(verts[b], v1);
        bool rev = vmatch(verts[a], v1) && vmatch(verts[b], v0);
        if (fwd || rev) return cast(int)i;
    }
    throw new Exception("edge not found: ("
        ~ v0[0].to!string ~ "," ~ v0[1].to!string ~ "," ~ v0[2].to!string ~ ")↔("
        ~ v1[0].to!string ~ "," ~ v1[1].to!string ~ "," ~ v1[2].to!string ~ ")");
}

double[3] toVec(JSONValue v) {
    auto a = v.array;
    double f(JSONValue j) {
        if (j.type == JSONType.float_)   return j.floating;
        if (j.type == JSONType.integer)  return cast(double)j.integer;
        if (j.type == JSONType.uinteger) return cast(double)j.uinteger;
        throw new Exception("expected number, got " ~ j.toString());
    }
    return [f(a[0]), f(a[1]), f(a[2])];
}

// Select the edge whose endpoints match (v0, v1) within tolerance.
void selectEdgeByEndpoints(double[3] v0, double[3] v1) {
    auto model = parseJSON(get(url("/api/model")));
    int idx = findEdgeIndex(model, v0, v1);
    auto sel = postJson("/api/select",
        `{"mode":"edges","indices":[` ~ idx.to!string ~ `]}`);
    if (sel["status"].str != "ok")
        throw new Exception("select failed: " ~ sel.toString());
}

void runSplitEdge(JSONValue op) {
    selectEdgeByEndpoints(toVec(op["v0"]), toVec(op["v1"]));
    auto resp = postJson("/api/command", `{"id":"mesh.split_edge"}`);
    if (resp["status"].str != "ok")
        throw new Exception("split_edge failed: " ~ resp.toString());
}

void runSubdivide(JSONValue op) {
    auto resp = postJson("/api/command", `{"id":"mesh.subdivide"}`);
    if (resp["status"].str != "ok")
        throw new Exception("subdivide failed: " ~ resp.toString());
}

void runMoveVertex(JSONValue op) {
    auto from = toVec(op["from"]);
    auto to_  = toVec(op["to"]);
    string body_ = `{"id":"mesh.move_vertex","params":{"from":[`
        ~ from[0].to!string ~ `,` ~ from[1].to!string ~ `,` ~ from[2].to!string
        ~ `],"to":[`
        ~ to_[0].to!string ~ `,` ~ to_[1].to!string ~ `,` ~ to_[2].to!string
        ~ `]}}`;
    auto resp = postJson("/api/command", body_);
    if (resp["status"].str != "ok")
        throw new Exception("move_vertex failed: " ~ resp.toString());
}

void runBevel(JSONValue op) {
    auto model = parseJSON(get(url("/api/model")));

    int[] indices;
    foreach (e; op["edges"].array) {
        double[3] v0 = toVec(e["v0"]);
        double[3] v1 = toVec(e["v1"]);
        indices ~= findEdgeIndex(model, v0, v1);
    }

    string idxStr;
    foreach (i, idx; indices) {
        if (i > 0) idxStr ~= ",";
        idxStr ~= idx.to!string;
    }
    auto sel = postJson("/api/select",
        `{"mode":"edges","indices":[` ~ idxStr ~ `]}`);
    if (sel["status"].str != "ok")
        throw new Exception("select failed: " ~ sel.toString());

    string params = `"width":` ~ op["width"].to!string
                  ~ `,"seg":` ~ op["segments"].to!string;
    if ("superR" in op)
        params ~= `,"superR":` ~ op["superR"].floating.to!string;
    if ("miter_inner" in op)
        params ~= `,"miter_inner":"` ~ op["miter_inner"].str.to!string ~ `"`;
    // Honor `clamp_overlap` (Blender's default = false / interactive bevel
    // doesn't clamp; vibe3d's MeshBevel.apply default = true). When the case
    // pins it, mirror to vibe3d's `limit` parameter.
    if ("clamp_overlap" in op)
        params ~= `,"limit":` ~ (op["clamp_overlap"].type == JSONType.true_
                                  ? "true" : "false");
    auto resp = postJson("/api/command",
        `{"id":"mesh.bevel","params":{` ~ params ~ `}}`);
    if (resp["status"].str != "ok")
        throw new Exception("bevel failed: " ~ resp.toString());
}

// Locate the face whose vertex set matches the given vertex coordinates
// (within EPS). Faces are matched by SET of vertex positions, ignoring
// winding/start; this lets a case identify a face by listing its corners
// in any order.
int findFaceIndex(JSONValue model, double[3][] faceVerts) {
    auto verts = model["vertices"].array;
    auto faces = model["faces"].array;

    bool vmatch(JSONValue v, double[3] target) {
        auto a = v.array;
        return abs(a[0].floating - target[0]) < 1e-4
            && abs(a[1].floating - target[1]) < 1e-4
            && abs(a[2].floating - target[2]) < 1e-4;
    }

    foreach (fi, f; faces) {
        auto fv = f.array;
        if (fv.length != faceVerts.length) continue;
        bool[] matched = new bool[](faceVerts.length);
        bool allOk = true;
        foreach (target; faceVerts) {
            bool found = false;
            foreach (j, vi; fv) {
                if (matched[j]) continue;
                if (vmatch(verts[vi.integer], target)) {
                    matched[j] = true;
                    found      = true;
                    break;
                }
            }
            if (!found) { allOk = false; break; }
        }
        if (allOk) return cast(int)fi;
    }
    throw new Exception("face not found with " ~ faceVerts.length.to!string ~ " verts");
}

void runPolyBevel(JSONValue op) {
    auto model = parseJSON(get(url("/api/model")));

    int[] faceIndices;
    foreach (f; op["faces"].array) {
        double[3][] fv;
        foreach (v; f.array) fv ~= toVec(v);
        faceIndices ~= findFaceIndex(model, fv);
    }

    string idxStr;
    foreach (i, idx; faceIndices) {
        if (i > 0) idxStr ~= ",";
        idxStr ~= idx.to!string;
    }
    auto sel = postJson("/api/select",
        `{"mode":"polygons","indices":[` ~ idxStr ~ `]}`);
    if (sel["status"].str != "ok")
        throw new Exception("select faces failed: " ~ sel.toString());

    string params = `"insert":` ~ op["insert"].floating.to!string
                  ~ `,"shift":`  ~ op["shift"].floating.to!string;
    if ("group" in op && op["group"].type == JSONType.true_)
        params ~= `,"group":true`;
    auto resp = postJson("/api/command",
        `{"id":"mesh.poly_bevel","params":{` ~ params ~ `}}`);
    if (resp["status"].str != "ok")
        throw new Exception("poly_bevel failed: " ~ resp.toString());
}

// Locate the vertex index whose position matches the given coordinates
// (within EPS). Throws on no match.
int findVertexIndex(JSONValue model, double[3] target) {
    auto verts = model["vertices"].array;
    foreach (i, v; verts) {
        auto a = v.array;
        if (abs(a[0].floating - target[0]) < 1e-4
         && abs(a[1].floating - target[1]) < 1e-4
         && abs(a[2].floating - target[2]) < 1e-4)
            return cast(int)i;
    }
    throw new Exception("vertex not found: ("
        ~ target[0].to!string ~ "," ~ target[1].to!string ~ "," ~ target[2].to!string ~ ")");
}

void runDeleteOrRemove(JSONValue op, string commandId) {
    string mode = op["mode"].str;
    auto model = parseJSON(get(url("/api/model")));

    int[] indices;
    if (mode == "polygons") {
        foreach (f; op["faces"].array) {
            double[3][] fv;
            foreach (v; f.array) fv ~= toVec(v);
            indices ~= findFaceIndex(model, fv);
        }
    } else if (mode == "edges") {
        foreach (e; op["edges"].array)
            indices ~= findEdgeIndex(model, toVec(e["v0"]), toVec(e["v1"]));
    } else if (mode == "vertices") {
        foreach (v; op["vertices"].array)
            indices ~= findVertexIndex(model, toVec(v));
    } else {
        throw new Exception("unknown delete/remove mode: " ~ mode);
    }

    string idxStr;
    foreach (i, idx; indices) {
        if (i > 0) idxStr ~= ",";
        idxStr ~= idx.to!string;
    }
    auto sel = postJson("/api/select",
        `{"mode":"` ~ mode ~ `","indices":[` ~ idxStr ~ `]}`);
    if (sel["status"].str != "ok")
        throw new Exception("select " ~ mode ~ " failed: " ~ sel.toString());

    auto resp = postJson("/api/command", `{"id":"` ~ commandId ~ `"}`);
    if (resp["status"].str != "ok")
        throw new Exception(commandId ~ " failed: " ~ resp.toString());
}

// Select verts by coord list and dispatch a vert.* command. Used by
// vert.merge / vert.join cases — the `params` JSON mirrors the
// command's argument schema.
void runVertCommand(JSONValue op, string commandId) {
    auto model = parseJSON(get(url("/api/model")));
    int[] indices;
    foreach (v; op["vertices"].array)
        indices ~= findVertexIndex(model, toVec(v));
    string idxStr;
    foreach (i, idx; indices) {
        if (i > 0) idxStr ~= ",";
        idxStr ~= idx.to!string;
    }
    auto sel = postJson("/api/select",
        `{"mode":"vertices","indices":[` ~ idxStr ~ `]}`);
    if (sel["status"].str != "ok")
        throw new Exception("select verts failed: " ~ sel.toString());

    string params;
    if (commandId == "vert.merge") {
        string range_ = ("range" in op) ? op["range"].str : "auto";
        double dist   = ("dist"  in op) ? op["dist"].floating : 0.001;
        bool   keep   = ("keep"  in op) ? (op["keep"].type == JSONType.true_) : false;
        params = `"range":"` ~ range_ ~ `","dist":` ~ dist.to!string
               ~ `,"keep":` ~ (keep ? "true" : "false");
    } else if (commandId == "vert.join") {
        bool avg   = ("average" in op) ? (op["average"].type == JSONType.true_) : true;
        bool keep  = ("keep"    in op) ? (op["keep"]   .type == JSONType.true_) : false;
        params = `"average":` ~ (avg  ? "true" : "false")
               ~ `,"keep":`   ~ (keep ? "true" : "false");
    }
    auto resp = postJson("/api/command",
        `{"id":"` ~ commandId ~ `","params":{` ~ params ~ `}}`);
    if (resp["status"].str != "ok")
        throw new Exception(commandId ~ " failed: " ~ resp.toString());
}

// Convert "X"|"Y"|"Z" axis label to a unit Vec3 string for the JSON
// payload of /api/transform.
string axisFromLabel(string label) {
    if (label == "X" || label == "x") return "[1,0,0]";
    if (label == "Y" || label == "y") return "[0,1,0]";
    if (label == "Z" || label == "z") return "[0,0,1]";
    throw new Exception("axis must be X/Y/Z, got '" ~ label ~ "'");
}

// Select every polygon in the current mesh — needed before mesh.transform
// (which is selection-aware) so a `rotate` / `scale` op affects all
// geometry. Switches edit mode to polygons via select.typeFrom first.
void selectAllPolygons() {
    auto resp = postJson("/api/command", "select.typeFrom polygon");
    if (resp["status"].str != "ok")
        throw new Exception("select.typeFrom polygon failed: " ~ resp.toString());
    auto model = parseJSON(get(url("/api/model")));
    long n = model["faceCount"].integer;
    string idxStr;
    foreach (i; 0 .. n) {
        if (i > 0) idxStr ~= ",";
        idxStr ~= i.to!string;
    }
    auto sel = postJson("/api/select",
        `{"mode":"polygons","indices":[` ~ idxStr ~ `]}`);
    if (sel["status"].str != "ok")
        throw new Exception("select-all failed: " ~ sel.toString());
}

// Accept JSON number as integer | uinteger | float and return double.
double readNum(JSONValue n) {
    switch (n.type) {
        case JSONType.integer:  return cast(double)n.integer;
        case JSONType.uinteger: return cast(double)n.uinteger;
        case JSONType.float_:   return n.floating;
        default: throw new Exception("expected number, got " ~ n.toString());
    }
}

double[3] readPivot(JSONValue op) {
    if ("pivot" !in op) return [0.0, 0.0, 0.0];
    auto a = op["pivot"].array;
    return [readNum(a[0]), readNum(a[1]), readNum(a[2])];
}

// Rotate every polygon by `angle` degrees around `axis` (X/Y/Z), pivoting
// at `pivot` (default origin). Maps to vibe3d's MeshTransform via
// /api/transform.
void runRotate(JSONValue op) {
    selectAllPolygons();
    string axis  = axisFromLabel(op["axis"].str);
    // Case files specify rotation in degrees (matches MODO Python /
    // user UX). vibe3d's /api/transform consumes radians (cos/sin
    // input), so convert at the boundary.
    double angDeg = readNum(op["angle"]);
    double angRad = angDeg * PI / 180.0;
    double[3] p   = readPivot(op);
    string body_ = `{"kind":"rotate","axis":` ~ axis
        ~ `,"angle":` ~ angRad.to!string
        ~ `,"pivot":[` ~ p[0].to!string ~ `,` ~ p[1].to!string ~ `,` ~ p[2].to!string ~ `]}`;
    auto resp = postJson("/api/transform", body_);
    if (resp["status"].str != "ok")
        throw new Exception("rotate failed: " ~ resp.toString());
}

// Scale every polygon by per-axis `factor` [fx, fy, fz], pivoting at
// `pivot` (default origin).
void runScale(JSONValue op) {
    selectAllPolygons();
    auto f = op["factor"].array;
    double[3] p  = readPivot(op);
    string body_ = `{"kind":"scale","factor":[`
        ~ readNum(f[0]).to!string ~ `,` ~ readNum(f[1]).to!string ~ `,` ~ readNum(f[2]).to!string
        ~ `],"pivot":[`
        ~ p[0].to!string ~ `,` ~ p[1].to!string ~ `,` ~ p[2].to!string ~ `]}`;
    auto resp = postJson("/api/transform", body_);
    if (resp["status"].str != "ok")
        throw new Exception("scale failed: " ~ resp.toString());
}

// Select a single polygon by listing its vertex coordinates (in any
// order). Sets edit mode to polygons.
void runSelectFace(JSONValue op) {
    auto resp0 = postJson("/api/command", "select.typeFrom polygon");
    if (resp0["status"].str != "ok")
        throw new Exception("select.typeFrom polygon failed: " ~ resp0.toString());
    auto model = parseJSON(get(url("/api/model")));
    double[3][] fv;
    foreach (v; op["face"].array) fv ~= toVec(v);
    int idx = findFaceIndex(model, fv);
    auto sel = postJson("/api/select",
        `{"mode":"polygons","indices":[` ~ idx.to!string ~ `]}`);
    if (sel["status"].str != "ok")
        throw new Exception("select_face failed: " ~ sel.toString());
}

void runWorkplaneAlign(JSONValue _op) {
    auto resp = postJson("/api/command", "workplane.alignToSelection");
    if (resp["status"].str != "ok")
        throw new Exception("workplane.alignToSelection failed: " ~ resp.toString());
}

// `prim.cube` argstring as an op (different shape from setup, which is
// one-shot at case start). Uses the same command dispatcher so the
// active workplane is honoured.
void runPrimCube(JSONValue op) {
    string argstr = "prim.cube";
    if ("params" in op && op["params"].type == JSONType.object) {
        foreach (string k, ref v; op["params"].objectNoRef) {
            argstr ~= " " ~ k ~ ":";
            if      (v.type == JSONType.string)   argstr ~= v.str;
            else if (v.type == JSONType.integer)  argstr ~= v.integer.to!string;
            else if (v.type == JSONType.uinteger) argstr ~= v.uinteger.to!string;
            else if (v.type == JSONType.float_)   argstr ~= v.floating.to!string;
            else if (v.type == JSONType.true_)    argstr ~= "true";
            else if (v.type == JSONType.false_)   argstr ~= "false";
        }
    }
    auto resp = postJson("/api/command", argstr);
    if (resp["status"].str != "ok")
        throw new Exception("prim.cube op failed: " ~ resp.toString());
}

// Phase 7.2h: scalar query results accumulated across the case's ops.
// Both vibe3d_dump and modo_dump produce the same dict shape; diff.py
// compares scalar-by-scalar with case tolerance.
JSONValue[string] queries;

// Helper: walk /api/toolpipe stages and return the named stage's
// `attrs` map.
JSONValue[string] findStageAttrs(string taskCode) {
    auto j = parseJSON(get(url("/api/toolpipe")));
    foreach (st; j["stages"].array) {
        if (st["task"].str == taskCode)
            return st["attrs"].object;
    }
    throw new Exception("stage " ~ taskCode ~ " missing from /api/toolpipe");
}

void runQueryAcen(JSONValue op) {
    string mode = op["mode"].str;
    auto resp = parseJSON(post(url("/api/command"),
                               "tool.pipe.attr actionCenter mode " ~ mode));
    if (resp["status"].str != "ok")
        throw new Exception("set actionCenter mode " ~ mode ~ " failed: "
                            ~ resp.toString());
    auto attrs = findStageAttrs("ACEN");
    string base = "actionCenter." ~ mode ~ ".";
    queries[base ~ "cenX"] = JSONValue(attrs["cenX"].str.to!float);
    queries[base ~ "cenY"] = JSONValue(attrs["cenY"].str.to!float);
    queries[base ~ "cenZ"] = JSONValue(attrs["cenZ"].str.to!float);
    queries[base ~ "mode"] = JSONValue(mode);
}

void runQueryAxis(JSONValue op) {
    string mode = op["mode"].str;
    auto resp = parseJSON(post(url("/api/command"),
                               "tool.pipe.attr axis mode " ~ mode));
    if (resp["status"].str != "ok")
        throw new Exception("set axis mode " ~ mode ~ " failed: "
                            ~ resp.toString());
    auto attrs = findStageAttrs("AXIS");
    string base = "axis." ~ mode ~ ".";
    // AxisStage publishes right/up/fwd; modo_dump uses axisX/Y/Z which
    // mirror MODO `axis.<mode>` attrs. Mapping: axisX = up.x (the
    // pole / forward axis is `up` in our convention; verify against
    // MODO via 7.2h cross-check).
    queries[base ~ "axisX"] = JSONValue(attrs["upX"].str.to!float);
    queries[base ~ "axisY"] = JSONValue(attrs["upY"].str.to!float);
    queries[base ~ "axisZ"] = JSONValue(attrs["upZ"].str.to!float);
}

// Phase 7.2h-extended: ACEN/AXIS round-trip cross-check via xfrm tools.
// vibe3d's /api/transform consumes raw world-space pivot+axis+delta,
// so the test reads the live ACEN center + AXIS basis from /api/
// toolpipe and feeds them through. MODO's xfrm.translate / xfrm.rotate
// implicitly consume action center / axis from the active stages, so
// MODO doesn't need this read-and-pass step. If both engines published
// the same ACEN/AXIS values, the resulting meshes match bit-for-bit.

void runActrSet(JSONValue op) {
    string preset = op["preset"].str;
    auto resp = parseJSON(post(url("/api/command"), "actr." ~ preset));
    if (resp["status"].str != "ok")
        throw new Exception("actr." ~ preset ~ " failed: " ~ resp.toString());
}

private double[3] readAxisDir(string handle) {
    auto a = findStageAttrs("AXIS");
    return [a[handle ~ "X"].str.to!double,
            a[handle ~ "Y"].str.to!double,
            a[handle ~ "Z"].str.to!double];
}

private double[3] readAcenCenter() {
    auto a = findStageAttrs("ACEN");
    return [a["cenX"].str.to!double,
            a["cenY"].str.to!double,
            a["cenZ"].str.to!double];
}

void runXfrmTranslate(JSONValue op) {
    string axis = "axis" in op ? op["axis"].str : "x";
    double dist = readNum(op["dist"]);
    string handle = (axis == "x") ? "right"
                  : (axis == "y") ? "up"
                                  : "fwd";
    auto dir = readAxisDir(handle);
    auto body_ = format(`{"kind":"translate","delta":[%.10g,%.10g,%.10g]}`,
                        dir[0] * dist, dir[1] * dist, dir[2] * dist);
    auto resp = parseJSON(post(url("/api/transform"), body_));
    if (resp["status"].str != "ok")
        throw new Exception("xfrm_translate failed: " ~ resp.toString());
}

void runXfrmRotate(JSONValue op) {
    string axis = "axis" in op ? op["axis"].str : "x";
    double angleDeg = readNum(op["angle"]);
    import std.math : PI;
    double angleRad = angleDeg * PI / 180.0;
    string handle = (axis == "x") ? "right"
                  : (axis == "y") ? "up"
                                  : "fwd";
    auto axisVec = readAxisDir(handle);
    auto pivot   = readAcenCenter();
    auto body_ = format(
        `{"kind":"rotate","axis":[%.10g,%.10g,%.10g],"angle":%.10g,"pivot":[%.10g,%.10g,%.10g]}`,
        axisVec[0], axisVec[1], axisVec[2], angleRad,
        pivot[0], pivot[1], pivot[2]);
    auto resp = parseJSON(post(url("/api/transform"), body_));
    if (resp["status"].str != "ok")
        throw new Exception("xfrm_rotate failed: " ~ resp.toString());
}

// Apply a soft-deform preset (xfrm.shear / xfrm.twist / xfrm.taper / ...)
// via tool.set + tool.pipe.attr (falloff handles) + tool.attr (transform
// magnitudes) + tool.doApply. Mirrors modo_dump.py:run_deform — the case
// JSON's `transform` keys map directly onto the matching tool's params
// (TX/TY/TZ on Move-based presets, RX/RY/RZ on Rotate, SX/SY/SZ on Scale).
//
// Selection: this runs in the current edit mode without changing it. The
// case's setup typically calls scene.reset (Vertices mode); deform tools
// fall back to whole-mesh in non-Polygons modes per source/tools/move.d
// MoveTool.applyHeadless's buildVertexCache contract. Cases that need a
// specific selection should add a select_face / select.typeFrom op
// before the deform op.
void runDeform(JSONValue op) {
    string preset = op["preset"].str;

    // Activate the preset — wires falloff stage + base transform tool.
    auto r = postJson("/api/command", "tool.set " ~ preset ~ " on");
    if (r["status"].str != "ok")
        throw new Exception("tool.set " ~ preset ~ " failed: " ~ r.toString);

    // Pin the falloff handles (overrides the auto-fit triggered by the
    // type set during preset activation). Vec3 values must be quoted —
    // the argstring parser only accepts barewords [a-zA-Z0-9_./-], the
    // comma in the literal forces the value through the quoted-string
    // branch.
    if ("falloff" in op) {
        auto fall = op["falloff"];
        string ftype = fall["type"].str;
        string vec3lit(JSONValue v) {
            auto a = v.array;
            return format(`"%g,%g,%g"`,
                          readNum(a[0]), readNum(a[1]), readNum(a[2]));
        }
        if (ftype == "linear") {
            postJson("/api/command",
                "tool.pipe.attr falloff start " ~ vec3lit(fall["start"]));
            postJson("/api/command",
                "tool.pipe.attr falloff end " ~ vec3lit(fall["end"]));
        } else if (ftype == "radial") {
            postJson("/api/command",
                "tool.pipe.attr falloff center " ~ vec3lit(fall["center"]));
            postJson("/api/command",
                "tool.pipe.attr falloff size " ~ vec3lit(fall["size"]));
        } else if (ftype == "cylinder") {
            // Cylinder falloff also takes the radial center+size, plus
            // an `axis` Vec3 (the cylinder direction). Default in
            // FalloffPacket is +Y if not specified.
            postJson("/api/command",
                "tool.pipe.attr falloff center " ~ vec3lit(fall["center"]));
            postJson("/api/command",
                "tool.pipe.attr falloff size " ~ vec3lit(fall["size"]));
            if ("axis" in fall)
                postJson("/api/command",
                    "tool.pipe.attr falloff axis " ~ vec3lit(fall["axis"]));
        } else {
            throw new Exception("deform falloff type '" ~ ftype ~ "'");
        }
        if ("shape" in fall)
            postJson("/api/command",
                "tool.pipe.attr falloff shape " ~ fall["shape"].str);
    }

    // Numeric transform attrs — applied to the active tool (= the
    // preset's base tool, which exposes TX/TY/TZ on Move, RX/RY/RZ on
    // Rotate, SX/SY/SZ on Scale via params() override).
    if ("transform" in op) {
        foreach (string k, ref v; op["transform"].objectNoRef) {
            auto resp = postJson("/api/command",
                format("tool.attr %s %s %g", preset, k, readNum(v)));
            if (resp["status"].str != "ok")
                throw new Exception("tool.attr " ~ preset ~ " " ~ k
                    ~ " failed: " ~ resp.toString);
        }
    }

    // One-shot apply — wraps applyHeadless in a snapshot pair for undo.
    auto applyResp = postJson("/api/command", "tool.doApply");
    if (applyResp["status"].str != "ok")
        throw new Exception("tool.doApply failed: " ~ applyResp.toString);
}

void runOp(JSONValue op) {
    switch (op["op"].str) {
        case "bevel":            runBevel(op);      break;
        case "split_edge":       runSplitEdge(op);  break;
        case "subdivide":        runSubdivide(op);  break;
        case "move_vertex":      runMoveVertex(op); break;
        case "polygon_bevel":    runPolyBevel(op);  break;
        case "delete":           runDeleteOrRemove(op, "mesh.delete"); break;
        case "remove":           runDeleteOrRemove(op, "mesh.remove"); break;
        case "vert.merge":       runVertCommand(op, "vert.merge"); break;
        case "vert.join":        runVertCommand(op, "vert.join");  break;
        case "rotate":           runRotate(op);          break;
        case "scale":            runScale(op);           break;
        case "select_face":      runSelectFace(op);      break;
        case "workplane_align":  runWorkplaneAlign(op);  break;
        case "prim_cube":        runPrimCube(op);        break;
        case "query_acen":       runQueryAcen(op);       break;
        case "query_axis":       runQueryAxis(op);       break;
        case "actr_set":         runActrSet(op);         break;
        case "xfrm_translate":   runXfrmTranslate(op);   break;
        case "xfrm_rotate":      runXfrmRotate(op);      break;
        case "deform":           runDeform(op);          break;
        default: throw new Exception("unknown op: " ~ op["op"].str);
    }
}

int main(string[] args) {
    if (args.length < 3) {
        stderr.writeln("usage: vibe3d_dump.d <case.json> <out.json> [--port N]");
        return 2;
    }
    string casePath = args[1];
    string outPath  = args[2];
    foreach (i; 3 .. args.length) {
        if (args[i] == "--port" && i + 1 < args.length) {
            port = args[i + 1].to!int;
        }
    }

    auto caseJson = parseJSON(readText(casePath));

    // Optional setup block — takes precedence over `primitive` field.
    if ("setup" in caseJson) {
        auto setup = caseJson["setup"];
        if ("kind" in setup && setup["kind"].str == "primitive") {
            // Reset to empty scene first, then build the primitive via /api/command.
            auto resetResp = postJson("/api/reset?empty=true", "");
            if (resetResp["status"].str != "ok")
                throw new Exception("reset(empty) failed: " ~ resetResp.toString());

            // Build argstring: "<tool> <name>:<value> ..."
            string toolName = setup["tool"].str;
            string argstr;
            if ("params" in setup && setup["params"].type == JSONType.object) {
                import std.conv : to;
                foreach (string k, ref v; setup["params"].objectNoRef) {
                    argstr ~= " " ~ k ~ ":";
                    if      (v.type == JSONType.string)   argstr ~= v.str;
                    else if (v.type == JSONType.integer)  argstr ~= v.integer.to!string;
                    else if (v.type == JSONType.uinteger) argstr ~= v.uinteger.to!string;
                    else if (v.type == JSONType.float_)   argstr ~= v.floating.to!string;
                    else if (v.type == JSONType.true_)    argstr ~= "true";
                    else if (v.type == JSONType.false_)   argstr ~= "false";
                    // Vec3 and other compound types are not handled in 6.0;
                    // phase-6 primitives use scalar params only.
                }
            }
            string line = toolName ~ argstr;
            auto cmdResp = postJson("/api/command", line);
            if (cmdResp["status"].str != "ok")
                throw new Exception("primitive setup '" ~ toolName ~ "' failed: "
                                    ~ cmdResp.toString());
        }
        // Future: setup.kind == "lwo" → load from file; "macro" → run script; etc.
    } else {
        // Legacy path: use `primitive` field (default: cube).
        string primitiveType = "cube";
        if ("primitive" in caseJson)
            primitiveType = caseJson["primitive"].str;
        resetMesh(primitiveType);
    }

    if ("preops" in caseJson)
        foreach (op; caseJson["preops"].array) runOp(op);
    foreach (op; caseJson["ops"].array) runOp(op);

    auto model = parseJSON(get(url("/api/model")));
    JSONValue out_ = JSONValue(["source": JSONValue("vibe3d")]);
    out_["vertexCount"] = model["vertexCount"];
    out_["faceCount"]   = model["faceCount"];
    out_["vertices"]    = model["vertices"];
    out_["faces"]       = model["faces"];
    if (queries.length > 0)
        out_["queries"] = JSONValue(queries);
    write(outPath, out_.toPrettyString());
    writefln("[vibe3d_dump] wrote %s: %d verts, %d faces",
        outPath, model["vertexCount"].integer, model["faceCount"].integer);
    return 0;
}
