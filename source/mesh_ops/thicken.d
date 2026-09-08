module mesh_ops.thicken;
// mesh-ops-import: explicit

import std.algorithm : reverse;
import std.array : uninitializedArray;
import std.math : abs;

import math : Vec3, safeNormalize;
import mesh;
import mesh_ops.bridge : bridgeLoopsPaired;

/// Build an offset copy of the surface (reversed winding), then stitch every
/// open boundary loop original↔offset with a ring of quads → closed shell.
/// Self-intersection on tight concavities is a known v1 limitation.
/// Returns total faces added (>0) or 0 (no-op: zero thickness or closed input).
///
/// Task 4602 moved this kernel out of the base Mesh module so its bridge
/// dependency points operation→operation→data. The batch is the sole receiver:
/// its `mesh` is both the data target and the active recorder frame established
/// by the caller.
size_t thickenSurface(ref MeshEditBatch ed, float thickness,
                      bool symmetric = false) {
    ref Mesh m = ed.mesh();

    // Step 1 — pre-mutation gates (mutation-free).
    if (abs(thickness) < 1e-6f) return 0;
    const size_t V0 = m.vertices.length;
    const size_t F0 = m.faces.length;
    uint[][] loops = m.boundaryLoops(F0);
    if (loops.length == 0) return 0;

    // Step 2 — per-vertex averaged unit face normals.
    // Must zero-init: D's float.init is nan, which poisons accumulation.
    Vec3[] vn = new Vec3[](V0);
    vn[] = Vec3(0, 0, 0);
    foreach (fi; 0 .. F0) {
        Vec3 fn = m.faceNormal(cast(uint)fi);
        foreach (vi; m.faces[fi])
            vn[vi] = vn[vi] + fn;
    }
    foreach (i; 0 .. V0)
        vn[i] = safeNormalize(vn[i]);

    // Step 3 — create offset vertices (offset pushed toward −normal side).
    uint[] off = new uint[](V0);
    if (!symmetric) {
        foreach (i; 0 .. V0)
            off[i] = m.addVertex(m.vertices[i] - vn[i] * thickness);
    } else {
        // --- TASK 1903 STAGE L2-h: THE SYMMETRIC SHIFT IS A `SetPos` ---
        //
        // This arm moves EVERY pre-existing vertex, and it used to do so
        // with a raw `vertices[i] = …` loop that reached no hook. A delta
        // recording only the appends restores the topology and leaves the
        // original surface at `orig + n·t/2` — and that is INVISIBLE on the
        // default `symmetric:false`, where this arm never runs, which is
        // why the parity fixture's `mesh.thicken` cell drives `true`.
        //
        // MEASURED BEFORE IT WAS TAKEN (plan §L2.9 Q-L2-2 asked for a
        // number, not a choice): on the perf stand the `SetPos` entry is a
        // fraction of the whole-mesh `MeshSnapshot` it replaces, so the arm
        // is migrated rather than left dense. The numbers are in the task
        // card.
        Vec3[] orig = new Vec3[](V0);
        foreach (i; 0 .. V0) orig[i] = m.vertices[i];
        {
            auto idx = uninitializedArray!(uint[])(V0);
            auto to  = uninitializedArray!(Vec3[])(V0);
            foreach (i; 0 .. V0) {
                idx[i] = cast(uint) i;
                to[i]  = orig[i] + vn[i] * (thickness * 0.5f);
            }
            // Publishes `Position` itself — the `commitChange` this
            // replaces is inside the door.
            m.setVertexPositions(idx, to);
        }
        foreach (i; 0 .. V0)
            off[i] = m.addVertex(orig[i] - vn[i] * (thickness * 0.5f));
    }

    // Step 4 — inner faces with reversed winding (inner skin faces −normal).
    // Task 0389: each shell face mirrors exactly one front face `fi` — it
    // inherits that face's Subpatch bit (rim quads, bridged below, then
    // pick this up automatically via bridgeLoopsPaired's own adjacency
    // OR — the rim is bounded by one front edge and its mirrored shell
    // edge, so it ORs this same bit with the front face's).
    foreach (fi; 0 .. F0) {
        uint[] of = new uint[](m.faces[fi].length);
        foreach (k; 0 .. m.faces[fi].length)
            of[k] = off[m.faces[fi][k]];
        reverse(of);
        // A FORWARD-ONLY GAP, NAMED (task 1903 §L2, revision 2):
        // `recordAddFace` carries the winding alone, so the subpatch bit
        // set two lines down is in no op-log entry. UNDO IS SAFE —
        // `AddFaces`' inverse truncates and the bit goes with the face —
        // and the loss is visible only to a FORWARD replay of a recorded
        // delta. Stage M inherits it, together with the same gap at
        // `mesh_ops/bridge.d`'s rim `addFace` and `poly_bevel.d`'s spike
        // fan.
        uint newFi = cast(uint)m.faces.length;
        m.addFace(of);
        m.resizeSubpatch();
        m.setFaceSubpatch(newFi, m.isFaceSubpatch(cast(uint)fi));
    }

    // Step 5 — bridge each stored boundary loop to its offset counterpart.
    // Outer boundary loops from boundaryLoops() are CCW (loop normal agrees
    // with face normal) → reverse for outward-facing rim quads.
    // Inner hole loops are CW (loop normal opposes face normal) → keep as-is.
    Vec3 avgN = Vec3(0, 0, 0);
    foreach (fi; 0 .. F0)
        avgN = avgN + m.faceNormal(cast(uint)fi);
    avgN = safeNormalize(avgN);

    size_t rimTotal = 0;
    foreach (ref loop; loops) {
        // Compute loop orientation via Newell's method.
        Vec3 ln = Vec3(0, 0, 0);
        const size_t LN = loop.length;
        foreach (k; 0 .. LN) {
            Vec3 a = m.vertices[loop[k]];
            Vec3 b = m.vertices[loop[(k + 1) % LN]];
            ln.x += (a.y - b.y) * (a.z + b.z);
            ln.y += (a.z - b.z) * (a.x + b.x);
            ln.z += (a.x - b.x) * (a.y + b.y);
        }
        if (ln.x * avgN.x + ln.y * avgN.y + ln.z * avgN.z > 0.0f)
            reverse(loop);

        uint[] pairedB = new uint[](LN);
        foreach (i; 0 .. LN)
            pairedB[i] = off[loop[i]];
        rimTotal += bridgeLoopsPaired(ed, loop, pairedB);
    }

    // Step 6 — finalize.
    m.buildLoops();
    m.syncSelection();
    return F0 + rimTotal;
}

// A member beats the UFCS free function silently. This build-time tripwire is
// the evidence that the move did not leave a shadowing copy in `Mesh`.
static assert(!__traits(hasMember, Mesh, "thickenSurface"),
    "Mesh.thickenSurface is a member again; keep the kernel in mesh_ops.thicken");

version (unittest) private void byValueGateAnchor() {}
