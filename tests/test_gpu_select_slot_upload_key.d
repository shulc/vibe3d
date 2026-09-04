// Task 1906 stage 2b, row 5 — THE `gpu_select` SLOT KEY'S `uploadVersion`
// TERM, pinned at last.
//
// ===========================================================================
// WHY
// ===========================================================================
// Stage 2b DELETED the proactive `gpuSelect.invalidate()` that fired from the
// change bus whenever the frame carried `Position | Geometry`, on the rule
// "key on the artifact you READ": `gpu_select` rasterises element IDs FROM THE
// VBO, and `GpuSelectBuffer.Slot.uploadVer == gpu.uploadVersion` fingerprints
// exactly what is in that buffer, so the mesh-side trigger was strictly
// dominated. That argument is only safe while the REMAINING key is itself
// pinned — otherwise both halves of a two-key cache have been retired, one on
// a mutation that reddened nothing and one on prose.
//
// It was not pinned. The plan's own mutation for the row — drop
// `slot.uploadVer` from `ensureSlot`'s predicate and expect "an existing
// gpu-select pick test after a subdivide" to redden — reddened NOTHING in
// `test_lasso_select`, `test_falloff_lasso_paint`, `test_element_pick_fresh_hover`
// or `test_wireframe_select_through` (measured 2026-08-25).
//
// THE REASON EVERY PICK-SHAPED CANDIDATE MISSES, and the shape this file had to
// take because of it: `ensureSlot` invalidates EVERY OTHER MODE's slot after a
// re-render (`foreach (mi, ref s; slots) if (mi != mode) s.valid = false;`), and
// in Vertices mode the per-frame hover pass runs `ensureSlot(SelectMode.Vertex)`
// on every frame. So a Face slot never survives to the next pick and a
// face-route test cannot observe a stale slot at all — the slot it would read
// was thrown away for an unrelated reason. The only observable is ONE MODE HELD
// CONTINUOUSLY ACROSS A GEOMETRY CHANGE, which is what a parked vertex hover is.
//
// ===========================================================================
// THE RIG
// ===========================================================================
//   park the cursor on the camera-nearest cube vertex   -> hover.vertex == V
//   /api/transform translate +1.0 in X                  -> the cube slides so
//     that a DIFFERENT vertex now occupies the pixel the cursor is parked on
//   read hover again                                    -> must be that OTHER
//     vertex
//
// +1.0 is chosen for a reason: the unit cube's width. It puts the vertex that
// was at (x-1, y, z) exactly where the parked one used to be, so the parked
// pixel stays a REAL, PICKABLE vertex — it does not merely go empty. That is
// the difference between this file and the weaker "hover becomes -1" version:
// -1 is also what a hover pass that STOPPED RUNNING reports, so the strong form
// asserts a NEW answer, which only a re-rendered ID buffer can produce.
//
// MUTATION (measured 2026-08-25): delete `&& slot.uploadVer == gpu.uploadVersion`
// from `gpu_select.d :: ensureSlot` →
//   the parked hover stays on vertex 6 after the cube moved a full width, while
//   vertex 7 sits 1.3 px from the cursor and every other vertex is >= 107 px
//   away.
// With the term present: 6 → 7.
//
// NOT A CALL-COUNT CHECK: a stale slot and a fresh one make the same number of
// picks down the same path. Only WHICH ELEMENT the ID buffer answers with
// separates them.
//
// Runner: ./run_test.d test_gpu_select_slot_upload_key

import http_client : testBaseUrl, getJson;
import std.net.curl : get, post;
import std.json;
import std.format : format;
import std.math   : sqrt;
import std.conv   : to;
import core.thread : Thread;
import core.time   : dur;

import drag_helpers : fetchCamera, viewportFromCamera, projectToWindow,
                      playAndWait, Vec3;

void main() {}

alias baseUrl = testBaseUrl;

void postJson(string path, string body_) {
    auto resp = cast(string)post(baseUrl ~ path, body_);
    auto j = parseJSON(resp);
    assert("error" !in j
        && (("status" !in j) || j["status"].str == "ok"
                             || j["status"].str == "success"),
        path ~ " failed: " ~ resp);
}


void settle(int ms = 400) { Thread.sleep(dur!"msecs"(ms)); }

int hoverVertex() { return cast(int)getJson("/api/toolpipe/eval")["hover"]["vertex"].integer; }

Vec3 vertOf(JSONValue m, size_t i) {
    auto a = m["vertices"].array[i].array;
    return Vec3(cast(float)a[0].floating,
                cast(float)a[1].floating,
                cast(float)a[2].floating);
}

/// Index of the vertex nearest `(px,py)` on screen, and its distance; plus the
/// distance of the SECOND nearest, so the caller can insist the answer is
/// unambiguous.
void nearestOnScreen(JSONValue m, int px, int py,
                     out int idx, out float d0, out float d1)
{
    auto vp = viewportFromCamera(fetchCamera());
    idx = -1; d0 = float.max; d1 = float.max;
    foreach (i; 0 .. m["vertices"].array.length) {
        float sx, sy;
        if (!projectToWindow(vertOf(m, i), vp, sx, sy)) continue;
        const float d = sqrt((sx - px) * (sx - px) + (sy - py) * (sy - py));
        if (d < d0) { d1 = d0; d0 = d; idx = cast(int)i; }
        else if (d < d1) d1 = d;
    }
    assert(idx >= 0, "no vertex projects at all — the camera rig is broken");
}

unittest {
    postJson("/api/reset", "");
    settle();

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    auto m0  = getJson("/api/model");

    // The camera-NEAREST vertex: on a convex body it is never occluded, so it
    // is pickable under any occlusion rule.
    int vid = -1;
    float best = float.max, px = 0, py = 0;
    foreach (i; 0 .. m0["vertices"].array.length) {
        Vec3 w = vertOf(m0, i);
        Vec3 d = w - cam.eye;
        const float d2 = d.x * d.x + d.y * d.y + d.z * d.z;
        if (d2 >= best) continue;
        float sx, sy;
        if (!projectToWindow(w, vp, sx, sy)) continue;
        best = d2; vid = cast(int)i; px = sx; py = sy;
    }
    assert(vid >= 0, "no projectable cube vertex");

    // Park the cursor. Three motions at the same spot: the hover answer is
    // recomputed by the per-frame pass, so one is enough in principle — the
    // repeats only make the park insensitive to which frame the player lands
    // the event in.
    playAndWait(
        format(`{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
               cam.vpX, cam.vpY, cam.width, cam.height)
      ~ format(`{"t":50.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n",
               cast(int)px, cast(int)py)
      ~ format(`{"t":80.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n",
               cast(int)px, cast(int)py)
      ~ format(`{"t":110.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n",
               cast(int)px, cast(int)py));
    settle();

    assert(hoverVertex() == vid,
        format("PREMISE: the cursor parked at (%d,%d) reports hover vertex %d, "
             ~ "expected %d — nothing below measures a STALE hover if the hover "
             ~ "never landed", cast(int)px, cast(int)py, hoverVertex(), vid));

    // Slide the cube by exactly its own width, so the parked pixel is occupied
    // by a DIFFERENT, still-pickable vertex.
    postJson("/api/select", `{"mode":"vertices","indices":[0,1,2,3,4,5,6,7]}`);
    settle();
    postJson("/api/transform", `{"kind":"translate","delta":[1.0,0,0]}`);
    settle(600);

    auto m1 = getJson("/api/model");
    int want; float d0, d1;
    nearestOnScreen(m1, cast(int)px, cast(int)py, want, d0, d1);
    assert(want != vid,
        format("PREMISE: after the slide the parked pixel is still nearest to "
             ~ "vertex %d — the displacement did not change WHICH vertex is "
             ~ "under the cursor, so a stale ID buffer and a fresh one would "
             ~ "agree", vid));
    assert(d0 < 4.0f && d1 > 40.0f,
        format("PREMISE: the parked pixel is %.1f px from vertex %d and %.1f px "
             ~ "from the next nearest — the answer must be unambiguous for the "
             ~ "pick radius (4 px) or a miss/hit says nothing", d0, want, d1));

    const int got = hoverVertex();
    assert(got == want,
        format("the parked hover reports vertex %d after the cube moved a full "
             ~ "width. Vertex %d is now %.1f px from the cursor and the next "
             ~ "nearest is %.1f px away, so %d is the only answer the CURRENT "
             ~ "geometry can give (%d was the answer BEFORE the move). The ID "
             ~ "buffer was not re-rendered against the new VBO — `gpu_select`'s "
             ~ "per-mode slot key no longer notices that `gpu.uploadVersion` "
             ~ "moved, and that term is the ONLY freshness key the buffer has "
             ~ "since stage 2b removed the change-bus trigger",
               got, want, d0, d1, want, vid));

    postJson("/api/reset", "");
}
