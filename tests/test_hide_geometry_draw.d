// Hide Geometry — Stage 3 (doc/hide_geometry_plan.md §6 S3): the BUILD-TIME
// filter. Hidden geometry leaves the GPU buffers in `GpuMesh.upload` and its
// three sibling builders, which is what takes it out of the viewport, out of
// the ID-buffer picker and out of that picker's depth pre-pass in one edit.
//
// Everything here reads through `/api/gpu/face-vbo` (the face / edge / vertex
// VBOs as the GPU actually holds them) and `/api/frames/counts` — never a
// screenshot, and never `/api/model` alone, because `/api/model` reports the
// MESH and this stage is about the BUFFERS. The two disagreeing is precisely
// the failure this file exists to catch: S2 already made `/api/model` report a
// hide, and it reported one for a while before any of it reached the screen.
//
// Every fixture is deliberately ASYMMETRIC about the thing under test — a
// mixed quad/triangle mesh for the per-face triangle count, a hidden element
// at index 0 for the slot mapping — so a wrong implementation reads a
// DIFFERENT NUMBER here rather than merely a missing effect.

import http_client : testBaseUrl, getJson, postJson;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.math : fabs, sqrt;
import std.conv : to;
import core.thread : Thread;
import core.time : msecs;

import drag_helpers;

void main() {}

alias BASE = testBaseUrl;


void runCmd(string id) {
    auto r = postJson("/api/command", `{"id":"` ~ id ~ `"}`);
    assert(r["status"].str == "ok", "/api/command " ~ id ~ " failed: " ~ r.toString);
}
void runScript(string s) {
    auto r = postJson("/api/command", s);
    assert(r["status"].str == "ok", "/api/command " ~ s ~ " failed: " ~ r.toString);
}

void selectMode(string mode, int[] indices) {
    string typeTok = mode == "polygons" ? "polygon" : (mode == "edges" ? "edge" : "vertex");
    runScript("select.typeFrom " ~ typeTok);
    string idxJson = "[";
    foreach (i, v; indices) { if (i > 0) idxJson ~= ","; idxJson ~= v.to!string; }
    idxJson ~= "]";
    auto r = postJson("/api/command", commandBody("mesh.select", `{"mode":"` ~ mode ~ `","indices":` ~ idxJson ~ `}`));
    assert(r["status"].str == "ok", "/api/select failed: " ~ r.toString);
}

// ---------------------------------------------------------------------------
// The observable: the GPU buffers, as uploaded.
// ---------------------------------------------------------------------------

struct GpuBuffers {
    int faceVertCount;
    int vertCount;
    int edgeVertCount;
    int edgeOriginLen;
    double[3][] facePositions;
    double[3][] vertPositions;
    double[3][] edgePositions;
}

double[3][] triples(JSONValue arr) {
    double[3][] r;
    foreach (t; arr.array) {
        auto a = t.array;
        double num(JSONValue v) {
            return v.type == JSONType.integer ? cast(double)v.integer
                 : v.type == JSONType.uinteger ? cast(double)v.uinteger
                 : v.floating;
        }
        r ~= [num(a[0]), num(a[1]), num(a[2])];
    }
    return r;
}

GpuBuffers gpuBuffers() {
    // No settle sleep on purpose: the provider runs `ensureDisplayCurrent()`
    // on the main thread first, which services any still-pending display
    // refresh synchronously. A sleep here would hide a missing publish behind
    // "the next frame uploaded it anyway", which is exactly the bug class this
    // file is guarding (the Marks-only publish that never reached the screen).
    auto j = getJson("/api/gpu/face-vbo");
    GpuBuffers g;
    g.faceVertCount = cast(int)j["faceVertCount"].integer;
    g.vertCount     = cast(int)j["vertCount"].integer;
    g.edgeVertCount = cast(int)j["edgeVertCount"].integer;
    g.edgeOriginLen = cast(int)j["edgeOriginLen"].integer;
    g.facePositions = triples(j["positions"]);
    g.vertPositions = triples(j["vertPositions"]);
    g.edgePositions = triples(j["edgePositions"]);
    return g;
}

JSONValue model() { return getJson("/api/model"); }

bool[] boolArray(JSONValue v) {
    bool[] r;
    foreach (b; v.array) r ~= b.type == JSONType.true_;
    return r;
}
bool[] faceHidden()   { return boolArray(model()["faceHidden"]); }
bool[] vertexHidden() { return boolArray(model()["vertexHidden"]); }
bool[] edgeHidden()   { return boolArray(model()["edgeHidden"]); }

double[3][] meshVertices() {
    return triples(model()["vertices"]);
}

int[2][] meshEdges() {
    int[2][] r;
    foreach (e; model()["edges"].array) {
        auto a = e.array;
        r ~= [cast(int)a[0].integer, cast(int)a[1].integer];
    }
    return r;
}

// Assert the edge VBO is "segment k = the k-th NON-HIDDEN cage edge", by
// ENDPOINT POSITION rather than by count. This is the edge-side twin of the
// vertex slot check: an unfiltered fill produces a buffer of the same shape
// holding DIFFERENT geometry from the first hidden edge onward, which a
// length assertion alone would wave through.
void assertEdgeVboMapping(ref GpuBuffers g, string where) {
    auto verts = meshVertices();
    auto edges = meshEdges();
    auto eh    = edgeHidden();
    size_t slot = 0;
    foreach (ei, e; edges) {
        if (ei < eh.length && eh[ei]) continue;
        assert(2*slot + 1 < g.edgePositions.length,
            where ~ ": edge VBO ran out of segments at cage edge "
            ~ ei.to!string);
        assert(near(g.edgePositions[2*slot],     verts[e[0]])
            && near(g.edgePositions[2*slot + 1], verts[e[1]]),
            where ~ ": edge VBO segment " ~ slot.to!string ~ " must be cage "
            ~ "edge " ~ ei.to!string ~ " " ~ fmt(verts[e[0]]) ~ "->"
            ~ fmt(verts[e[1]]) ~ ", got " ~ fmt(g.edgePositions[2*slot])
            ~ "->" ~ fmt(g.edgePositions[2*slot + 1]));
        ++slot;
    }
    assert(2 * slot == g.edgePositions.length,
        where ~ ": edge VBO holds " ~ (g.edgePositions.length / 2).to!string
        ~ " segments but the mesh has " ~ slot.to!string
        ~ " visible edges");
}

int countTrue(bool[] a) { int n = 0; foreach (b; a) if (b) ++n; return n; }

bool near(double[3] a, double[3] b, double eps = 1e-4) {
    return fabs(a[0]-b[0]) < eps && fabs(a[1]-b[1]) < eps && fabs(a[2]-b[2]) < eps;
}

string fmt(double[3] p) {
    return "(" ~ p[0].to!string ~ "," ~ p[1].to!string ~ "," ~ p[2].to!string ~ ")";
}

void resetEmpty() {
    auto r = parseJSON(cast(string)post(BASE ~ "/api/reset?empty=true", ""));
    assert(r["status"].str == "ok", "/api/reset?empty=true failed: " ~ r.toString);
    runCmd("history.clear");
}
void resetCube() {
    auto r = postJson("/api/reset", "");
    assert(r["status"].str == "ok", "/api/reset failed: " ~ r.toString);
    runCmd("history.clear");
}

// Select every cube edge BY INDEX and prove it landed. There is no
// `select.all` command, and — the reason this is a helper rather than one
// line inline — an EMPTY edge selection produces the same edges-pass draw
// numbers as a FULL one (drawEdges' `selectedEdges.length == 0` gray-pass
// fast path submits the whole buffer in one call, and so does the
// allEdgesSelected highlight shortcut). So a T-S3d row that merely forgot to
// select would read the expected 1 call / 24 verts and prove nothing. The
// assertion below is what stops that.
void selectAllTwelveEdges() {
    selectMode("edges", [0,1,2,3,4,5,6,7,8,9,10,11]);
    auto sel = getJson("/api/selection");
    assert("selectedEdges" in sel && sel["selectedEdges"].array.length == 12,
        "fixture needs all 12 cube edges selected — an EMPTY selection reads "
        ~ "the same draw counts, so this row would be vacuous without it; got "
        ~ sel.toString);
}

// ---------------------------------------------------------------------------
// T-S3a — hidden faces leave the face VBO but KEEP their slot (R3).
// ---------------------------------------------------------------------------

unittest {
    // The fixture is a 4-face strip with TWO QUADS AND TWO TRIANGLES, and the
    // hidden pair is one of each. That mix is the whole point (plan T-S3a): a
    // wrong implementation that decrements the triangle count by a fixed
    // per-face constant reads a different number than the correct 6 + 3.
    // A cube — six identical quads — cannot tell those apart, and neither can
    // any fixture whose hidden faces have the same corner count.
    //
    //   v4---v5---v6---v7          f0 = quad [0,1,5,4]   6 VBO verts
    //    |    |    | \  |          f1 = quad [1,2,6,5]   6
    //   v0---v1---v2---v3          f2 = tri  [2,3,6]     3
    //                              f3 = tri  [3,7,6]     3
    //
    // Hidden: f0 (quad) + f2 (triangle). They share no vertex, so the fixture
    // is also asymmetric in the derived planes.
    resetEmpty();
    auto lr = parseJSON(cast(string)post(BASE ~ "/api/load-mesh", `{
        "vertices": [[0,0,0],[1,0,0],[2,0,0],[3,0,0],
                     [0,0,1],[1,0,1],[2,0,1],[3,0,1]],
        "faces": [[0,1,5,4],[1,2,6,5],[2,3,6],[3,7,6]]
    }`));
    assert(lr["status"].str == "ok", "/api/load-mesh failed: " ~ lr.toString);
    runCmd("history.clear");

    auto before = gpuBuffers();
    assert(before.faceVertCount == 18,
        "fixture must upload 6+6+3+3 = 18 face verts, got "
        ~ before.faceVertCount.to!string ~ " — the fixture is not the "
        ~ "quad/triangle mix this test needs");
    assert(before.vertCount == 8 && before.edgeVertCount == 22,
        "fixture must start with 8 verts and 11 edges, got vertCount="
        ~ before.vertCount.to!string ~ " edgeVertCount="
        ~ before.edgeVertCount.to!string);

    immutable size_t faceCountBefore = model()["faces"].array.length;
    assert(faceCountBefore == 4);

    selectMode("polygons", [0, 2]);
    runCmd("mesh.hide");

    auto after = gpuBuffers();

    // The face VBO shrinks by the hidden faces' OWN triangle counts…
    assert(after.faceVertCount == 9,
        "hiding one quad (6 VBO verts) + one triangle (3) must drop the face "
        ~ "VBO from 18 to 9; got " ~ after.faceVertCount.to!string
        ~ ". 6 would mean a fixed 6-per-face decrement (both treated as "
        ~ "quads); 12 would mean a fixed 3-per-face one.");

    // …while the mesh keeps every face, and so does the SLOT array the face
    // picker's `maxId` is derived from (R3). If a hidden face were dropped
    // from `faceTriStart` instead of zeroed, face-ID translation would shift.
    assert(model()["faces"].array.length == faceCountBefore,
        "hiding must not remove a face from the mesh");
    auto fh = faceHidden();
    assert(fh == [true, false, true, false],
        "expected faces {0,2} hidden, got " ~ fh.to!string);

    // Derived planes, and their effect on the other two buffers. v0 and v4 sit
    // only on f0, so exactly those two go hidden; the three edges touching
    // them go with them. Asserted as counts AND identities so "the right
    // number of the wrong elements" fails.
    auto vh = vertexHidden();
    assert(vh == [true, false, false, false, true, false, false, false],
        "only v0 and v4 (whose sole incident face is the hidden f0) may be "
        ~ "hidden, got " ~ vh.to!string);
    assert(after.vertCount == 6,
        "vertex VBO must drop the 2 hidden verts (8 -> 6), got "
        ~ after.vertCount.to!string);
    assert(countTrue(edgeHidden()) == 3,
        "3 edges touch v0/v4, got " ~ countTrue(edgeHidden()).to!string);
    assert(after.edgeVertCount == 16,
        "edge VBO must drop 3 segments (22 -> 16 verts), got "
        ~ after.edgeVertCount.to!string);
    assertEdgeVboMapping(after, "T-S3a upload");
}

// ---------------------------------------------------------------------------
// T-S3b — the drag-refresh path keeps `upload`'s layout (R2).
// ---------------------------------------------------------------------------

unittest {
    // The vertex / edge VBOs stop being cage-indexed the moment something is
    // hidden: slot k becomes the k-th VISIBLE element. This asserts that
    // mapping — before AND after a real gizmo drag, so a drag-time rebuild
    // that disagreed with `upload` would show up as a shifted buffer.
    //
    // The discriminator is that the hidden vertex is at index 0: a builder
    // that forgot the skip does not merely produce a SHORTER buffer, it
    // produces a SHIFTED one, so slot 0 holds cage v0 instead of cage v1 —
    // a DIFFERENT position, not a missing one. Hiding a high-index vertex
    // could not tell those apart, and asserting only the count could not
    // either.
    //
    // HONEST SCOPE NOTE, because the plan's R2 names a specific function this
    // test does NOT reach. R2 is about `uploadSelectedVertices`
    // (tools/transform/transform.d:491). MEASURED on this build: a move-gizmo
    // drag of one selected vertex calls it ZERO times — `XfrmTransformTool`
    // folds the drag into `u_model` and does one full `gpu.upload` at
    // mouse-up, so neither `uploadToGpu` nor `uploadSelectedVertices` fires.
    // Its copy of the skip predicate is therefore written and reviewed but
    // NOT covered by any assertion here; breaking it leaves this test green.
    // What the drag below does cover is that the layout survives a real
    // gesture end-to-end on the path the tool actually takes.
    resetCube();
    auto verts = meshVertices();
    assert(verts.length == 8, "cube fixture");

    // Hide every face around cube vertex 0 ⇒ v0 (and only v0) derives hidden.
    selectMode("vertices", [0]);
    runCmd("mesh.hide");
    auto vh = vertexHidden();
    assert(vh[0] && countTrue(vh) == 1,
        "fixture needs EXACTLY vertex 0 hidden, got " ~ vh.to!string);

    auto beforeDrag = gpuBuffers();
    assert(beforeDrag.vertCount == 7,
        "vertex VBO must hold the 7 visible verts, got "
        ~ beforeDrag.vertCount.to!string);
    assertEdgeVboMapping(beforeDrag, "upload");
    // Slot 0 is cage v1, not cage v0 — the whole mapping, checked per slot so
    // a shift anywhere fails, not just at the seam.
    foreach (k; 0 .. beforeDrag.vertCount) {
        immutable size_t cage = k + 1;   // v0 is the only hidden one
        assert(near(beforeDrag.vertPositions[k], verts[cage]),
            "upload: vertex VBO slot " ~ k.to!string ~ " must be cage v"
            ~ cage.to!string ~ " " ~ fmt(verts[cage]) ~ ", got "
            ~ fmt(beforeDrag.vertPositions[k]) ~ " — an unfiltered fill puts "
            ~ "cage v" ~ k.to!string ~ " " ~ fmt(verts[k]) ~ " there instead");
    }

    // Now drag a VISIBLE vertex with the move gizmo. One moving vertex out of
    // eight keeps `uploadToGpu` on the partial branch, i.e. through
    // uploadSelectedVertices rather than a full upload — which is the path
    // under test. Vertex 6 is the far corner from the hidden one.
    selectMode("vertices", [6]);
    auto setResp = post(BASE ~ "/api/script", "tool.set move");
    assert(parseJSON(cast(string)setResp)["status"].str == "ok",
        "tool.set move failed: " ~ cast(string)setResp);

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    Thread.sleep(200.msecs);   // gizmo handles publish after a drawn frame

    double sx0, sy0;
    bool found;
    fetchHandlePart(0, sx0, sy0, found);
    assert(found, "X-move handle (part 0) missing from /api/tool/handles");

    Vec3 pivot = Vec3(cast(float)verts[6][0], cast(float)verts[6][1],
                      cast(float)verts[6][2]);
    float pxs, pys, nxs, nys;
    assert(projectToWindow(pivot, vp, pxs, pys), "pivot off-camera");
    assert(projectToWindow(Vec3(pivot.x + 1.0f, pivot.y, pivot.z), vp, nxs, nys),
        "pivot+X off-camera");
    double sdx = nxs - pxs, sdy = nys - pys;
    double sLen = sqrt(sdx*sdx + sdy*sdy);
    assert(sLen > 1.0, "world +X projects too short to drive a drag");
    int x0 = cast(int)sx0, y0 = cast(int)sy0;
    int x1 = x0 + cast(int)(100.0 * sdx / sLen);
    int y1 = y0 + cast(int)(100.0 * sdy / sLen);

    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             x0, y0, x1, y1, 20));
    Thread.sleep(150.msecs);

    auto movedVerts = meshVertices();
    assert(movedVerts[6][0] - verts[6][0] > 0.1,
        "the drag must actually move v6 in +X (dx="
        ~ (movedVerts[6][0] - verts[6][0]).to!string ~ ") — without a real "
        ~ "drag this test measures nothing");

    auto afterDrag = gpuBuffers();

    // Same LENGTH…
    assert(afterDrag.vertCount == beforeDrag.vertCount,
        "the drag refresh must not change the vertex VBO length: "
        ~ beforeDrag.vertCount.to!string ~ " -> "
        ~ afterDrag.vertCount.to!string);
    assert(afterDrag.edgeVertCount == beforeDrag.edgeVertCount,
        "the drag refresh must not change the edge VBO length: "
        ~ beforeDrag.edgeVertCount.to!string ~ " -> "
        ~ afterDrag.edgeVertCount.to!string);

    assertEdgeVboMapping(afterDrag, "after drag");
    // …and the same MAPPING. Slot k must still be the k-th VISIBLE cage
    // vertex, now at its post-drag position. Checked for every slot, so a
    // shift anywhere in the buffer fails, not just at the seam.
    foreach (k; 0 .. afterDrag.vertCount) {
        immutable size_t cage = k + 1;   // v0 is the only hidden one
        assert(near(afterDrag.vertPositions[k], movedVerts[cage]),
            "after the drag, vertex VBO slot " ~ k.to!string
            ~ " must be cage v" ~ cage.to!string ~ " "
            ~ fmt(movedVerts[cage]) ~ ", got "
            ~ fmt(afterDrag.vertPositions[k])
            ~ " — a cage-indexed scatter write puts cage v" ~ k.to!string
            ~ " " ~ fmt(movedVerts[k]) ~ " there instead");
    }
}

// ---------------------------------------------------------------------------
// T-S3c — hiding does not deform the limit surface (R5).
// ---------------------------------------------------------------------------

unittest {
    // Hide is stamped onto the subdivision's OUTPUT marks and is never fed to
    // its INPUT. Assert that on the NEIGHBOURS: a hidden cage face's own
    // preview children disappear either way, so their absence proves nothing.
    // If the hidden face were withheld from the OSD input, the subdivided
    // subset would gain a boundary there and every surviving limit vertex
    // around it would MOVE.
    //
    // So: every position still in the preview after the hide must be a
    // position that was in it before, to 1e-4. An input-side mistake breaks
    // that for the whole ring around the hidden face at once.
    resetCube();
    selectMode("polygons", [0, 1, 2, 3, 4, 5]);
    runCmd("mesh.subpatch_toggle");
    Thread.sleep(250.msecs);

    auto before = gpuBuffers();
    assert(before.faceVertCount > 36,
        "the subpatch preview must be live and subdivided (face VBO "
        ~ before.faceVertCount.to!string ~ " verts) — without it this test "
        ~ "measures the cage and proves nothing about the limit surface");

    selectMode("polygons", [2]);
    runCmd("mesh.hide");
    Thread.sleep(250.msecs);

    auto after = gpuBuffers();
    assert(after.faceVertCount > 0 && after.faceVertCount < before.faceVertCount,
        "hiding one cage face must shrink the preview's face VBO: "
        ~ before.faceVertCount.to!string ~ " -> "
        ~ after.faceVertCount.to!string);

    size_t moved = 0;
    double worst = 0;
    double[3] worstP;
    foreach (p; after.facePositions) {
        bool matched = false;
        double best = double.max;
        foreach (q; before.facePositions) {
            double d = sqrt((p[0]-q[0])*(p[0]-q[0]) + (p[1]-q[1])*(p[1]-q[1])
                          + (p[2]-q[2])*(p[2]-q[2]));
            if (d < best) best = d;
            if (d < 1e-4) { matched = true; break; }
        }
        if (!matched) { ++moved; if (best > worst) { worst = best; worstP = p; } }
    }
    assert(moved == 0,
        "hiding a cage face moved " ~ moved.to!string ~ " surviving limit "
        ~ "vertices (worst " ~ fmt(worstP) ~ " is " ~ worst.to!string
        ~ " from anything in the pre-hide surface) — Hide reached the "
        ~ "subdivision INPUT, not just its output marks");
}

// ---------------------------------------------------------------------------
// T-S3d — the `edgeOriginGpu` sentinel stays conditional (R11 / R12).
// ---------------------------------------------------------------------------

unittest {
    // `edgeOriginGpu.length > 0` is not a lookup table, it is the SENTINEL for
    // "this edge VBO is not 1:1 with the mesh's edges" — read with that
    // meaning by drawEdges' allEdgesSelected shortcut, by gpu_select's
    // id-translation branch, and by uploadSelectedVertices' cage-identity
    // comment. Populating it unconditionally would redefine it for every mesh
    // in the program.
    //
    // Row (i): nothing hidden ⇒ length 0. An unconditional population reads
    // 24 here (the cube's edge count), which is the number this row exists to
    // separate.
    resetCube();
    selectAllTwelveEdges();

    auto clean = gpuBuffers();
    assert(clean.edgeVertCount == 24,
        "cube fixture: 12 edges = 24 VBO verts, got "
        ~ clean.edgeVertCount.to!string);
    assert(clean.edgeOriginLen == 0,
        "with nothing hidden the edge VBO IS cage-identity, so the sentinel "
        ~ "must stay empty; got " ~ clean.edgeOriginLen.to!string
        ~ " (an unconditional population reads 12 here and permanently "
        ~ "stands down drawEdges' allEdgesSelected shortcut)");

    // NOTE on what is deliberately NOT asserted here. The plan's T-S3d row (i)
    // proposed `pass[edges].calls`. MEASURED: it is 1 either way. With the
    // shortcut live, the gray pass is skipped and the highlight pass issues
    // one whole-buffer call; with the shortcut stood down, the gray pass
    // batches every segment out (0 calls) and the highlight pass batches the
    // one contiguous selected run (1 call). Same count. Asserting it would
    // have been an inert test that passes under the very implementation it was
    // written to reject — the sentinel above is the observable that separates
    // them.

    // Row (ii): something hidden ⇒ the sentinel exists, sized to the KEPT
    // edges, and the edges draw pass submits exactly 2 verts fewer per hidden
    // edge. `verts`, not `calls`: a batched path hides a count change in a
    // call count.
    // WHY THE EXPECTED NUMBER IS DOUBLED (task 1860). The selection highlight
    // is now submitted TWICE per frame — once depth-tested normally, once
    // against the inverted depth comparison at the occluded alpha — so an
    // all-edges-selected cube puts its 24-vert buffer through the edges pass
    // twice. The factor is spelled out rather than folded into a literal 48,
    // for two reasons: this row would otherwise read as "the buffer is 48
    // verts long", which is false; and if the occluded pass is ever dropped
    // the numbers here go back to 24/18 and BOTH rows redden with a message
    // that names the pass count, instead of one bare arithmetic mismatch.
    enum long kHighlightPasses = 2;

    auto cleanCounts = getJson("/api/frames/counts");
    immutable long cleanVerts = cleanCounts["lastScene"]["pass"]["edges"]["verts"].integer;
    assert(cleanVerts == 24 * kHighlightPasses,
        "edges pass must submit the whole 24-vert buffer once per highlight "
        ~ "pass when all edges are selected and none hidden: expected "
        ~ (24 * kHighlightPasses).to!string ~ " ("
        ~ kHighlightPasses.to!string ~ " x 24), got " ~ cleanVerts.to!string);

    selectMode("vertices", [0]);
    runCmd("mesh.hide");
    immutable int hiddenEdges = countTrue(edgeHidden());
    assert(hiddenEdges == 3,
        "hiding the three faces around v0 hides exactly the 3 edges at v0, "
        ~ "got " ~ hiddenEdges.to!string);

    selectMode("edges", [0,1,2,3,4,5,6,7,8,9,10,11]);
    Thread.sleep(200.msecs);

    auto dirty = gpuBuffers();
    assert(dirty.edgeVertCount == 24 - 2 * hiddenEdges,
        "the edge VBO must lose 2 verts per hidden edge: expected "
        ~ (24 - 2*hiddenEdges).to!string ~ ", got "
        ~ dirty.edgeVertCount.to!string);
    assert(dirty.edgeOriginLen == 12 - hiddenEdges,
        "with edges skipped the VBO is no longer cage-identity, so the "
        ~ "sentinel must be populated with one entry per KEPT edge: expected "
        ~ (12 - hiddenEdges).to!string ~ ", got "
        ~ dirty.edgeOriginLen.to!string);

    auto dirtyCounts = getJson("/api/frames/counts");
    immutable long dirtyVerts = dirtyCounts["lastScene"]["pass"]["edges"]["verts"].integer;
    // Per hidden edge the buffer loses 2 verts, and each of the highlight
    // passes stops submitting them — so the drop is 2 x kHighlightPasses per
    // hidden edge, not 2. Written through the same constant as the row above
    // so the two cannot disagree about how many passes there are.
    assert(dirtyVerts == cleanVerts - 2 * kHighlightPasses * hiddenEdges,
        "the edges draw pass must submit 2 fewer verts per hidden edge PER "
        ~ "highlight pass: " ~ (cleanVerts - 2*kHighlightPasses*hiddenEdges).to!string
        ~ " expected (" ~ cleanVerts.to!string ~ " - 2 x "
        ~ kHighlightPasses.to!string ~ " x " ~ hiddenEdges.to!string
        ~ "), got " ~ dirtyVerts.to!string);

    // And it goes back. `unhideAll` must restore the sentinel to EMPTY, not
    // merely refill it at full length — otherwise the shortcut is disabled for
    // the rest of the session by a hide the user already undid.
    runCmd("mesh.unhideAll");
    auto restored = gpuBuffers();
    assert(restored.edgeVertCount == 24 && restored.edgeOriginLen == 0,
        "unhideAll must restore both the full edge VBO and the EMPTY "
        ~ "sentinel, got edgeVertCount=" ~ restored.edgeVertCount.to!string
        ~ " edgeOriginLen=" ~ restored.edgeOriginLen.to!string);
}

// ---------------------------------------------------------------------------
// T-S3e — a hide reaches the buffers at all, and an undo takes it back.
// ---------------------------------------------------------------------------

unittest {
    // The stage's cheapest and most load-bearing assertion, and the one that
    // was RED for two separate reasons while `/api/model` already reported the
    // hide correctly:
    //
    //   1. the hide published `Marks`, which display_sync.DisplayRefreshMask
    //      deliberately excludes (it would re-upload on every selection
    //      click), so app.d's bus-driven upload never fired — measured: the
    //      face VBO sat at 36 verts with a face hidden;
    //   2. the command's revert() restored all three marks arrays wholesale
    //      and published `Marks` too, so Ctrl+Z put the geometry back in the
    //      model and left it invisible on screen — measured: 30 after undo.
    //
    // Both directions are asserted, because each was independently broken.
    resetCube();
    auto fresh = gpuBuffers();
    assert(fresh.faceVertCount == 36 && fresh.vertCount == 8
        && fresh.edgeVertCount == 24,
        "cube fixture: 36 face verts / 8 verts / 24 edge verts, got "
        ~ fresh.faceVertCount.to!string ~ "/" ~ fresh.vertCount.to!string
        ~ "/" ~ fresh.edgeVertCount.to!string);

    selectMode("vertices", [0]);
    runCmd("mesh.hide");
    auto hidden = gpuBuffers();
    assert(hidden.faceVertCount == 18 && hidden.vertCount == 7
        && hidden.edgeVertCount == 18,
        "hiding the 3 faces at v0 must drop the buffers to 18/7/18, got "
        ~ hidden.faceVertCount.to!string ~ "/" ~ hidden.vertCount.to!string
        ~ "/" ~ hidden.edgeVertCount.to!string
        ~ " — 36/8/24 means the hide never reached the GPU upload");

    auto u = postJson("/api/undo", "");
    assert(u["status"].str == "ok", "/api/undo failed: " ~ u.toString);
    auto undone = gpuBuffers();
    assert(undone.faceVertCount == 36 && undone.vertCount == 8
        && undone.edgeVertCount == 24 && undone.edgeOriginLen == 0,
        "undo must put the geometry back on the GPU, not just in the model; "
        ~ "got " ~ undone.faceVertCount.to!string ~ "/"
        ~ undone.vertCount.to!string ~ "/" ~ undone.edgeVertCount.to!string
        ~ " sentinel=" ~ undone.edgeOriginLen.to!string);
    assert(countTrue(faceHidden()) == 0,
        "undo must clear the hidden set in the model too");

    auto rd = postJson("/api/redo", "");
    assert(rd["status"].str == "ok", "/api/redo failed: " ~ rd.toString);
    auto redone = gpuBuffers();
    assert(redone.faceVertCount == 18 && redone.vertCount == 7
        && redone.edgeVertCount == 18,
        "redo must re-apply the hide to the GPU buffers, got "
        ~ redone.faceVertCount.to!string ~ "/" ~ redone.vertCount.to!string
        ~ "/" ~ redone.edgeVertCount.to!string);
}
