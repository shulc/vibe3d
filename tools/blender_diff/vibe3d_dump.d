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
import std.math : abs;
import std.net.curl;
import std.stdio;
import std.string : startsWith;

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
    auto resp = postJson("/api/command",
        `{"id":"mesh.bevel","params":{` ~ params ~ `}}`);
    if (resp["status"].str != "ok")
        throw new Exception("bevel failed: " ~ resp.toString());
}

void runOp(JSONValue op) {
    switch (op["op"].str) {
        case "bevel":       runBevel(op);      break;
        case "split_edge":  runSplitEdge(op);  break;
        case "subdivide":   runSubdivide(op);  break;
        case "move_vertex": runMoveVertex(op); break;
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

    string primitiveType = "cube";
    if ("primitive" in caseJson)
        primitiveType = caseJson["primitive"].str;
    resetMesh(primitiveType);
    if ("preops" in caseJson)
        foreach (op; caseJson["preops"].array) runOp(op);
    foreach (op; caseJson["ops"].array) runOp(op);

    auto model = parseJSON(get(url("/api/model")));
    JSONValue out_ = JSONValue(["source": JSONValue("vibe3d")]);
    out_["vertexCount"] = model["vertexCount"];
    out_["faceCount"]   = model["faceCount"];
    out_["vertices"]    = model["vertices"];
    out_["faces"]       = model["faces"];
    write(outPath, out_.toPrettyString());
    writefln("[vibe3d_dump] wrote %s: %d verts, %d faces",
        outPath, model["vertexCount"].integer, model["faceCount"].integer);
    return 0;
}
