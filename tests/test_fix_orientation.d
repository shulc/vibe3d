// Tests for mesh.fixOrientation (task 0394 Part B) -- the "Fix Orientation"
// cleanup op that heals inconsistently-wound faces (the free function
// fixFaceOrientation in source/mesh_ops/cleanup.d, over ref MeshEditBatch --
// task 1903 Stage E1 moved it off Mesh). Corruption is injected the same way
// test_mesh_flip-style tests do: select a face via /api/select, then run
// mesh.flip (an existing, already-tested command that reverses winding) to
// deterministically reverse exactly one face of the default cube, without
// needing to hand-author a raw vertex/face JSON fixture.

import std.net.curl;
import std.json;
import std.conv : to;
import std.format : format;

void main() {}

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------

string baseUrl = "http://localhost:8080";

void postReset() {
    auto resp = post(baseUrl ~ "/api/reset", "");
    assert(parseJSON(resp)["status"].str == "ok", "/api/reset failed: " ~ resp);
}

JSONValue postCommandRaw(string body) {
    return parseJSON(cast(string) post(baseUrl ~ "/api/command", body));
}

void postCommand(string body) {
    auto r = postCommandRaw(body);
    assert(r["status"].str == "ok", "command failed: " ~ r.toString);
}

JSONValue postUndo() {
    return parseJSON(cast(string) post(baseUrl ~ "/api/undo", ""));
}

JSONValue getModel() {
    return parseJSON(cast(string) get(baseUrl ~ "/api/model"));
}

long undoCount() {
    return parseJSON(cast(string) get(baseUrl ~ "/api/history"))["undo"].array.length;
}

JSONValue getChanges() {
    return parseJSON(cast(string) get(baseUrl ~ "/api/changes"));
}

void selectFaces(int[] idx) {
    string[] parts;
    foreach (i; idx) parts ~= i.to!string;
    string body = `{"mode":"polygons","indices":[` ~ joinCommas(parts) ~ `]}`;
    auto r = parseJSON(cast(string) post(baseUrl ~ "/api/select", body));
    assert(r["status"].str == "ok", "select failed: " ~ r.toString);
}

string joinCommas(string[] parts) {
    string s;
    foreach (i, p; parts) { if (i > 0) s ~= ","; s ~= p; }
    return s;
}

// Extract face fi's ordered vertex-index array from a /api/model response.
int[] faceVerts(JSONValue model, size_t fi) {
    int[] r;
    foreach (v; model["faces"].array[fi].array) r ~= cast(int)v.integer;
    return r;
}

// ---------------------------------------------------------------------------
// mesh.fixOrientation
// ---------------------------------------------------------------------------

unittest { // no-op on the clean default cube: false evaluate -> no undo entry
    postReset();
    const depthBefore = undoCount();
    cast(void) post(baseUrl ~ "/api/command", `{"id":"mesh.fixOrientation"}`);
    assert(undoCount() == depthBefore,
        "no-op fixOrientation on the clean default cube must not add an undo entry");
}

unittest { // one corrupted face is healed; vertex/face counts unchanged; undo restores
    postReset();
    auto before = getModel();
    const nFaces = before["faceCount"].integer;
    const nVerts = before["vertexCount"].integer;
    auto originalFace2 = faceVerts(before, 2);

    // Corrupt exactly face 2 via the already-tested mesh.flip command.
    selectFaces([2]);
    postCommand(`{"id":"mesh.flip"}`);
    auto corrupted = getModel();
    assert(faceVerts(corrupted, 2) != originalFace2, "sanity: face 2 must now be reversed");

    // Clear selection so fixOrientation processes the WHOLE mesh (no restriction).
    selectFaces([]);

    postCommand(`{"id":"mesh.fixOrientation"}`);
    auto fixed = getModel();
    assert(fixed["faceCount"].integer   == nFaces, "fixOrientation must not change face count");
    assert(fixed["vertexCount"].integer == nVerts, "fixOrientation must not change vertex count");
    assert(faceVerts(fixed, 2) == originalFace2,
        "fixOrientation must restore face 2's original winding");

    // No same-direction shared edge remains anywhere in the mesh.
    auto facesArr = fixed["faces"].array;
    foreach (fi, fv; facesArr) {
        auto f = fv.array;
        foreach (k; 0 .. f.length) {
            int u = cast(int)f[k].integer, v = cast(int)f[(k + 1) % f.length].integer;
            foreach (fj, gv; facesArr) {
                if (fj == fi) continue;
                auto g = gv.array;
                foreach (kk; 0 .. g.length) {
                    if (cast(int)g[kk].integer == u && cast(int)g[(kk + 1) % g.length].integer == v)
                        assert(false, format("same-direction shared edge (%d,%d) remains between faces %d and %d",
                                              u, v, fi, fj));
                }
            }
        }
    }

    // Undo restores the corrupted state exactly.
    postUndo();
    auto undone = getModel();
    assert(faceVerts(undone, 2) != originalFace2,
        "undo must restore the corrupted (reversed) face 2 winding");
}

unittest { // idempotent: a second run right after a successful fix is itself a no-op
    postReset();
    selectFaces([1]);
    postCommand(`{"id":"mesh.flip"}`);
    selectFaces([]);

    postCommand(`{"id":"mesh.fixOrientation"}`); // first run: fixes it
    const depthAfterFirst = undoCount();

    cast(void) post(baseUrl ~ "/api/command", `{"id":"mesh.fixOrientation"}`); // second run: already consistent
    assert(undoCount() == depthAfterFirst,
        "a second fixOrientation run on an already-consistent mesh must not add an undo entry");
}

// ---------------------------------------------------------------------------
// The edit-seam observable of mesh.fixOrientation (task 1903 Stage E1). It is
// invisible to every other test in this file: the healed winding is identical
// whether or not `fixFaceOrientation` runs inside a batch. What separates
// those worlds is the change-bus counters at /api/changes.
// ---------------------------------------------------------------------------
unittest { // mesh.fixOrientation runs its kernel inside ONE edit batch
    postReset();
    selectFaces([0]);

    // POSITIVE CONTROL. Every assertion below is "this counter did not move",
    // and a dead counter satisfies that for free. mesh.flip is the command
    // this file already uses to INJECT the corruption, it mutates, and it is
    // deliberately still batchless — so it is both the setup and the proof
    // that the counter is alive.
    auto c0 = getChanges();
    postCommand(`{"id":"mesh.flip"}`);
    auto c1 = getChanges();
    const long ctrl = c1["unbatchedGeometryCommits"].integer
                    - c0["unbatchedGeometryCommits"].integer;
    assert(ctrl > 0,
        format("positive control: an UNBATCHED command must tick "
             ~ "unbatchedGeometryCommits, and mesh.flip ticked %d. A dead "
             ~ "counter passes the assertions below for free "
             ~ "(task 1903 §3.2 L2, M-DM).", ctrl));

    auto before = getChanges();
    postCommand(`{"id":"mesh.fixOrientation"}`);
    auto after = getChanges();

    const long unbatched = after["unbatchedGeometryCommits"].integer
                         - before["unbatchedGeometryCommits"].integer;
    assert(unbatched == 0,
        format("mesh.fixOrientation made %d UNBATCHED geometry commit(s). The "
             ~ "kernel's receiver is `ref MeshEditBatch`, so the "
             ~ "flipFacesByMask commit must defer into the frame and stamp "
             ~ "once at close(); a non-zero delta means the batch does not "
             ~ "cover the kernel (task 1903 Stage E1, plan §3.2 L2). Pre-E1 "
             ~ "this was +1.", unbatched));

    // Anti-vacuity: a REJECTED fixOrientation moves no counter at all, so the
    // zero above would be free. The undo entry is what says it applied.
    assert(undoCount() > 0,
        "mesh.fixOrientation recorded no undo entry — it was rejected, and "
      ~ "the delta assertion above is vacuous on a rejected command");

    assert(after["nestedBatchOpens"].integer
        == c0["nestedBatchOpens"].integer,
        "mesh.fixOrientation moved changeBus.nestedBatchOpens. Its batch is "
      ~ "opened at the command boundary and nowhere else; this family has no "
      ~ "intra-Mesh caller and therefore owes no transitional batch "
      ~ "(task 1903 Stage E1, plan §4.4a).");
    assert(after["batchLeaks"].integer == 0,
        "a MeshEditBatch leaked (destroyed while still open): "
      ~ after["batchLeaks"].integer.to!string);
    assert(after["missedPublishers"].integer == 0,
        "a mutationVersion bump reached the frame with no pending change: "
      ~ after["missedPublishers"].integer.to!string);
}
