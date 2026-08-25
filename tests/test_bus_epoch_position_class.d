// Task 1906 stage 2a — DOES THE `Position` CLASS ACTUALLY REACH THE DIRTY
// EPOCHS? The cell that separates "the epoch feed carries the right classes"
// from "the epoch feed carries everything".
//
// ===========================================================================
// WHY THIS FILE EXISTS
// ===========================================================================
// Stage 2a made the display family key on `mesh_dirty.g_displayEpochs`, whose
// listener (`noteMeshChange`, fed from the change-bus hub AND from the flush
// block's per-layer loop) forwards a mutation's CHANGE CLASSES. Nothing pinned
// that the classes matter. Measured at review time (2026-08-25): strip
// `Position` from BOTH feeds — `noteMeshChange(addr, flags & ~Position)` — and
// `test_bus_position_pixel`, `test_bus_surface_raycast_after_drag`,
// `test_display_bus_refresh`, `test_subpatch_move`, `test_gpu_fold_parity` and
// `test_far_pivot_fold` are ALL still green. Six tests, no discrimination.
//
// The reason the closest candidate misses is worth writing down, because it is
// the trap this file had to design around. `test_bus_surface_raycast_after_drag`
// ARM A drives a version-silent gizmo drag, which publishes `Position` and
// nothing else — but its rig must PROMOTE the background layer to primary
// first, and `app.d`'s active-layer hook publishes `MeshChangeAll` on the new
// primary. `Points|Polygons` are inside the geometry watcher's mask, so that
// promotion alone advances the epoch and the BVH rebuilds whether `Position`
// ever arrives or not (traced at the feed, 2026-08-25: `flags=63` at the
// promotion, epoch 17 → 19, before a single drag step).
//
// ===========================================================================
// THE RIG
// ===========================================================================
// One window with exactly ONE geometry-class publication in it, and that
// publication is `Position`:
//
//   reset → settle → select every vertex → SNAPSHOT /api/changes
//   → /api/transform translate  (mesh.transform → commitChange(Position))
//   → SNAPSHOT /api/changes again
//
// The two snapshots are the premise, not decoration: `totalPosition` must have
// moved and `totalPoints`/`totalPolygons` must NOT have. If a future change
// makes `mesh.transform` publish a second geometry class, this file stops
// discriminating — and the premise assert says so instead of going quietly
// vacuous.
//
// THE OBSERVABLE IS THE BUFFER, NOT A CALL COUNT. `/api/gpu/face-vbo`'s
// `vertPositions` is a readback of the cage vertex VBO — what the viewport
// actually rasterises. A missed invalidation gives byte-identical call counts
// and a buffer that still holds the pre-transform cube; only the readback can
// tell them apart.
//
// MUTATION (measured 2026-08-25): `flags & ~MeshEditScope.Position` at the hub
// (`app.d`'s `changeBus.onMeshChanged`) and at the per-layer feed in the flush
// block →
//   the cage vertex VBO holds vertex 0 at x=-0.500 while the mesh has it at
//   x=1.500 (max |mesh - VBO| = 2.0)
// because the flush-site upload's `displayServiced_` stamp still matches.
//
// Runner: ./run_test.d test_bus_epoch_position_class

import std.net.curl : get, post;
import std.json;
import std.format : format;
import std.math   : fabs;
import core.thread : Thread;
import core.time   : dur;

void main() {}

enum baseUrl = "http://localhost:8080";

void postJson(string path, string body_) {
    auto resp = cast(string)post(baseUrl ~ path, body_);
    auto j = parseJSON(resp);
    assert("error" !in j
        && (("status" !in j) || j["status"].str == "ok"
                             || j["status"].str == "success"),
        path ~ " failed: " ~ resp);
}

JSONValue getJson(string path) {
    return parseJSON(cast(string)get(baseUrl ~ path));
}

void settle(int ms = 300) { Thread.sleep(dur!"msecs"(ms)); }

long counter(JSONValue ch, string key) { return ch[key].integer; }

unittest {
    postJson("/api/reset", "");
    settle();

    // Baseline: the VBO already agrees with the mesh, so any disagreement
    // below is the transform's, not a pre-existing one.
    {
        auto m0 = getJson("/api/model")["vertices"].array;
        auto g0 = getJson("/api/gpu/face-vbo");
        assert(g0["vertCount"].integer == cast(long)m0.length,
            format("baseline: the cage vertex VBO holds %d verts, the mesh has "
                 ~ "%d — the readback is not describing this mesh at all",
                   g0["vertCount"].integer, m0.length));
        auto p0 = g0["vertPositions"].array;
        foreach (i, v; m0)
            foreach (k; 0 .. 3)
                assert(fabs(v.array[k].floating - p0[i].array[k].floating) < 1e-4,
                    "baseline: the cage VBO does not match the reset mesh");
    }

    postJson("/api/select", `{"mode":"vertices","indices":[0,1,2,3,4,5,6,7]}`);
    settle();

    auto before = getJson("/api/changes");
    const double x0 = getJson("/api/model")["vertices"].array[0].array[0].floating;

    // The ONE publication in the window. `mesh.transform` ends in
    // `commitChange(MeshEditScope.Position)`.
    postJson("/api/transform", `{"kind":"translate","delta":[2.0,0,0]}`);
    settle();

    auto after = getJson("/api/changes");

    // ---- PREMISE 1: the window really did move the mesh. -------------------
    auto m = getJson("/api/model")["vertices"].array;
    const double x1 = m[0].array[0].floating;
    assert(fabs(x1 - x0 - 2.0) < 1e-3,
        format("PREMISE: the translate did not land — vertex 0 went from "
             ~ "x=%.4f to x=%.4f, expected +2.0. Nothing below means anything "
             ~ "if the mesh did not move", x0, x1));

    // ---- PREMISE 2: and it published `Position` AND NOTHING ELSE from the
    // geometry classes. This is what makes the assert below a test OF THE
    // CLASS rather than of the epoch machinery in general. ------------------
    assert(counter(after, "totalPosition") > counter(before, "totalPosition"),
        "PREMISE: the translate published no Position class at all — the "
      ~ "publisher changed and this cell is measuring something else");
    assert(counter(after, "totalPoints")   == counter(before, "totalPoints")
        && counter(after, "totalPolygons") == counter(before, "totalPolygons"),
        format("PREMISE: the window published a SECOND geometry class "
             ~ "(Points %d->%d, Polygons %d->%d). Either of those advances the "
             ~ "display/geometry epochs on its own, so this file would go "
             ~ "green with `Position` dropped from the feed entirely — i.e. it "
             ~ "would stop being the cell it exists to be. Fix the rig, do not "
             ~ "relax this assert",
               counter(before, "totalPoints"),   counter(after, "totalPoints"),
               counter(before, "totalPolygons"), counter(after, "totalPolygons")));

    // ---- THE ASSERT: the buffer the viewport draws followed the mesh. ------
    auto g = getJson("/api/gpu/face-vbo");
    assert(g["vertCount"].integer == cast(long)m.length,
        "the cage vertex VBO changed length across a pure translate");
    auto p = g["vertPositions"].array;
    double worst = 0;
    size_t worstIdx = 0;
    foreach (i, v; m) {
        foreach (k; 0 .. 3) {
            const double d = fabs(v.array[k].floating - p[i].array[k].floating);
            if (d > worst) { worst = d; worstIdx = i; }
        }
    }
    assert(worst < 1e-4,
        format("the cage vertex VBO did not follow a Position-only change: "
             ~ "vertex %d is at %s in the mesh and %s in the buffer "
             ~ "(max |mesh - VBO| = %.4f). The flush-site upload is gated on "
             ~ "the display-class bus EPOCH, so the only way this happens is "
             ~ "that the `Position` class never reached "
             ~ "`mesh_dirty.noteMeshChange` — the epoch feed dropped the one "
             ~ "class an interactive transform publishes",
               worstIdx, m[worstIdx].toString, p[worstIdx].toString, worst));

    postJson("/api/reset", "");
}
