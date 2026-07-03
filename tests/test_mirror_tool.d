// Tests for the interactive Mirror tool (mesh.mirrorTool), task 0227.
//
// Modelled on tests/test_primitive_box_interactive.d (interactive tool via
// tool.set/tool.attr) and tests/test_mesh_mirror.d (assertions on the
// resulting mesh). Mirror is a generator tool (BoxTool template) wrapping
// the existing, tested Mesh.mirrorFaces (source/mesh.d:4172) — the aim of
// these cases is PARITY with the mesh.mirror command for equal params, plus
// the interactive-tool-specific concerns (commit-on-deactivate, the
// `engaged` no-accidental-mirror guard, headless one-shot not double
// applying).

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : abs;

void main() {}

enum string BASE = "http://localhost:8080";
enum string TOOL = "mesh.mirrorTool";

// Helpers ------------------------------------------------------------------

void resetCube() {
    auto resp = post(BASE ~ "/api/reset", "");
    assert(parseJSON(resp)["status"].str == "ok",
        "/api/reset failed: " ~ resp);
}

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(BASE ~ path, body_));
}

// Argstring one-liner (scalar attrs: axis/mergeVerts/invertPolys/distance).
void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}

// Vec3 attr write — the argstring positional path only carries a single
// trailing value (app.d's ToolAttrCommand branch reads pos[0]/pos[1]/pos[2]
// only), so a 3-component vec3 write goes through the JSON `_positional`
// form directly: pos[2] becomes the JSON array [x,y,z] verbatim, which
// injectParamsInto's Vec3_ case accepts.
void attrVec3(string toolId, string attrName, double x, double y, double z) {
    string body_ = `{"id":"tool.attr","params":{"_positional":["` ~ toolId
        ~ `","` ~ attrName ~ `",[` ~ x.to!string ~ "," ~ y.to!string ~ ","
        ~ z.to!string ~ `]]}}`;
    auto r = postJson("/api/command", body_);
    assert(r["status"].str == "ok", "attrVec3 '" ~ attrName ~ "' failed: " ~ r.toString);
}

void toolSet(string toolId) { cmd("tool.set " ~ toolId); }
void toolOff(string toolId) { cmd("tool.set " ~ toolId ~ " off"); }

JSONValue getModel()     { return parseJSON(cast(string) get(BASE ~ "/api/model")); }
JSONValue getSelection() { return parseJSON(cast(string) get(BASE ~ "/api/selection")); }

bool approxEq(double a, double b, double eps = 1e-5) {
    return abs(a - b) < eps;
}

// ---------------------------------------------------------------------------
// 1. Parity vs the mesh.mirror command — whole-mesh, no weld, flip on.
// ---------------------------------------------------------------------------

unittest { // interactive tool with equal params matches the command exactly
    resetCube();
    cmd(`{"id":"mesh.mirror","params":{
        "axis":"X","center":[1,0,0],"weld":0,"flip_normals":true
    }}`);
    auto expected = getModel();

    resetCube();
    toolSet(TOOL);
    cmd("tool.attr " ~ TOOL ~ " axis X");
    attrVec3(TOOL, "center", 1, 0, 0);
    cmd("tool.attr " ~ TOOL ~ " mergeVerts false");
    cmd("tool.attr " ~ TOOL ~ " invertPolys true");
    toolOff(TOOL);
    auto actual = getModel();

    assert(actual["vertexCount"].integer == expected["vertexCount"].integer,
        "vertex count mismatch: expected " ~ expected["vertexCount"].toString
        ~ ", got " ~ actual["vertexCount"].toString);
    assert(actual["faceCount"].integer == expected["faceCount"].integer,
        "face count mismatch: expected " ~ expected["faceCount"].toString
        ~ ", got " ~ actual["faceCount"].toString);
    assert(actual["edgeCount"].integer == expected["edgeCount"].integer,
        "edge count mismatch: expected " ~ expected["edgeCount"].toString
        ~ ", got " ~ actual["edgeCount"].toString);

    // Byte-identical vertex positions (both start from the same reset cube
    // and run the identical mirrorFaces call).
    auto ev = expected["vertices"].array;
    auto av = actual["vertices"].array;
    assert(ev.length == av.length);
    foreach (i; 0 .. ev.length) {
        auto e = ev[i].array; auto a = av[i].array;
        assert(approxEq(e[0].floating, a[0].floating)
            && approxEq(e[1].floating, a[1].floating)
            && approxEq(e[2].floating, a[2].floating),
            "vertex " ~ i.to!string ~ " mismatch");
    }
}

// ---------------------------------------------------------------------------
// 2. Whole-mesh default (empty selection ⇒ all faces) — defaults only.
// ---------------------------------------------------------------------------

unittest { // No selection, no attr writes beyond center ⇒ mirrors the whole
           // cube like the command's whole-mesh path (axis defaults to X).
    resetCube();
    toolSet(TOOL);
    attrVec3(TOOL, "center", 1, 0, 0);
    cmd("tool.attr " ~ TOOL ~ " mergeVerts false");
    toolOff(TOOL);

    auto m = getModel();
    assert(m["vertexCount"].integer == 16,
        "verts: expected 16, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 12,
        "faces: expected 12, got " ~ m["faceCount"].integer.to!string);
}

// ---------------------------------------------------------------------------
// 3. Merge on + distance — seam face dropped (mirrors test_mesh_mirror.d).
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    toolSet(TOOL);
    attrVec3(TOOL, "center", 0.5, 0, 0);
    cmd("tool.attr " ~ TOOL ~ " mergeVerts true");
    cmd("tool.attr " ~ TOOL ~ " distance 0.001");
    toolOff(TOOL);

    auto m = getModel();
    assert(m["vertexCount"].integer == 12,
        "verts: expected 12, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 11,
        "faces: expected 11, got " ~ m["faceCount"].integer.to!string);
}

// ---------------------------------------------------------------------------
// 4. Invert on/off changes winding of the cloned face.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    auto sresp = postJson("/api/select", `{"mode":"polygons","indices":[0]}`);
    assert(sresp["status"].str == "ok");

    toolSet(TOOL);
    cmd("tool.attr " ~ TOOL ~ " axis Z");
    attrVec3(TOOL, "center", 0, 0, 1);
    cmd("tool.attr " ~ TOOL ~ " mergeVerts false");
    cmd("tool.attr " ~ TOOL ~ " invertPolys false");
    toolOff(TOOL);

    auto m = getModel();
    auto faces  = m["faces"].array;
    auto orig   = faces[0].array;
    auto cloned = faces[6].array;
    auto verts  = m["vertices"].array;
    foreach (i; 0 .. orig.length) {
        auto oArr = verts[cast(size_t) orig[i].integer].array;
        auto cArr = verts[cast(size_t) cloned[i].integer].array;
        assert(approxEq(cArr[0].floating, oArr[0].floating)
            && approxEq(cArr[1].floating, oArr[1].floating)
            && approxEq(cArr[2].floating, 2.0 - oArr[2].floating),
            "invertPolys=false: cloned[i] should mirror orig[i] in order (i=" ~ i.to!string ~ ")");
    }
}

// ---------------------------------------------------------------------------
// 5. Undo restores the pre-mirror cube — one entry only.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    toolSet(TOOL);
    attrVec3(TOOL, "center", 1, 0, 0);
    cmd("tool.attr " ~ TOOL ~ " mergeVerts false");
    toolOff(TOOL);

    auto post_ = getModel();
    assert(post_["faceCount"].integer == 12);

    auto undoResp = postJson("/api/undo", "");
    assert(undoResp["status"].str == "ok", "undo failed: " ~ undoResp.toString);

    auto m = getModel();
    assert(m["vertexCount"].integer == 8);
    assert(m["faceCount"].integer == 6);
    assert(m["edgeCount"].integer == 12);
}

// ---------------------------------------------------------------------------
// 6. No interaction ⇒ no mirror (the `engaged` guard, §4.2 of the impl plan).
// ---------------------------------------------------------------------------

unittest { // Activate and immediately deactivate without any attr write —
           // must NOT mirror anything (accidental-mirror guard).
    resetCube();
    auto before = getModel();

    toolSet(TOOL);
    toolOff(TOOL);

    auto after = getModel();
    assert(after["vertexCount"].integer == before["vertexCount"].integer,
        "untouched activate/deactivate must not mirror");
    assert(after["faceCount"].integer == before["faceCount"].integer,
        "untouched activate/deactivate must not mirror");
}

// ---------------------------------------------------------------------------
// 7. Headless one-shot (ToolHeadlessCommand) — no double-apply.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    cmd(`{"id":"` ~ TOOL ~ `","params":{
        "axis":"X","center":[1,0,0],"mergeVerts":false
    }}`);

    auto m = getModel();
    assert(m["vertexCount"].integer == 16,
        "headless: verts expected 16, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 12,
        "headless: faces expected 12, got " ~ m["faceCount"].integer.to!string);

    // One-shot recorded exactly one undo entry.
    auto undoResp = postJson("/api/undo", "");
    assert(undoResp["status"].str == "ok", "undo failed: " ~ undoResp.toString);
    auto restored = getModel();
    assert(restored["vertexCount"].integer == 8);
    assert(restored["faceCount"].integer == 6);
}

// ---------------------------------------------------------------------------
// 8. Non-cumulative preview (M3) — repeated center edits during the SAME
// session must not accumulate mirrors. The preview itself is `!testMode`
// visual (no GPU asserts here — see the module unittest in
// source/tools/mirror.d for the CPU-only preview-rebuild proof); this case
// asserts on the COMMITTED count after `off`, matching the plan's case 6.
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    toolSet(TOOL);
    cmd("tool.attr " ~ TOOL ~ " mergeVerts false");
    // Five successive center edits — each one re-evaluates the (own) preview
    // internally; only the FINAL value should ever land in the committed
    // mesh, once, on deactivate.
    attrVec3(TOOL, "center", 0.2, 0, 0);
    attrVec3(TOOL, "center", 0.4, 0, 0);
    attrVec3(TOOL, "center", 0.6, 0, 0);
    attrVec3(TOOL, "center", 0.8, 0, 0);
    attrVec3(TOOL, "center", 1.0, 0, 0);
    toolOff(TOOL);

    auto m = getModel();
    assert(m["faceCount"].integer == 12,
        "non-cumulative: expected single-mirror 12 faces, got "
        ~ m["faceCount"].integer.to!string);
    assert(m["vertexCount"].integer == 16,
        "non-cumulative: expected single-mirror 16 verts, got "
        ~ m["vertexCount"].integer.to!string);
}
