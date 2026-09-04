// Task 1930 stage 1 — THE `gpu_select` SLOT KEY'S CAMERA TERM (`view`, `proj`),
// pinned BEFORE the refactor that gives it a name.
//
// ===========================================================================
// WHY
// ===========================================================================
// `GpuSelectBuffer.ensureSlot` keys its cached ID-render on six terms:
// (mode, gpu.uploadVersion, view, proj, FBO size, occlude). Task 1906 stage 2b
// pinned `uploadVersion` (tests/test_gpu_select_slot_upload_key.d) after
// finding it un-witnessed; `occlude` is pinned by the display-style work of
// task 1830. The CAMERA half — `matricesEqual(slot.view, mv) &&
// matricesEqual(slot.proj, vp.proj)` — has been un-witnessed since it was
// written: deleting both lines reddened nothing in the tree.
//
// Task 1930 folds those two terms into one `CameraStamp` value. A refactor
// that moves an UNPINNED compare cannot tell "moved it correctly" from
// "dropped it", so this file is written FIRST, against today's two
// `matricesEqual` lines, and stays green across the fold. Plan 1906 §5 row 3
// ("delete the new `CameraStamp.changed` compare — an orbit-drag pick test")
// is the same mutation one stage later, and this is the test it names.
//
// ===========================================================================
// THE RIG
// ===========================================================================
//   park the cursor on the camera-nearest cube vertex   -> hover.vertex == V
//   POST /api/camera azimuth = 0.5 + PI/2 (ABSOLUTE)    -> the camera orbits a
//     quarter turn about world Y; the PICTURE is unchanged, but a DIFFERENT
//     vertex index now occupies the pixel the cursor is parked on
//   read hover again                                    -> must be that OTHER
//     index
//
// THE DELTA IS CONSTRUCTED, NOT SEARCHED — the exact analogue of "+1.0 = the
// cube's width" in the `uploadVersion` sibling:
//
//   * `Orientation.fromAngles(az, el, roll)` builds `r0 = (ca, 0, -sa)` and
//     `b = (ce*sa, se, ce*ca)`. Substituting `az -> az + PI/2` gives
//     `r0' = (-sa, 0, -ca)` and `b' = (ce*ca, se, -ce*sa)` — that is exactly
//     `R_y(PI/2)` applied to both. So "azimuth is a rotation about world Y" is
//     an identity here, not an assumption.
//   * `/api/reset` puts the camera at `fromAngles(0.5, 0.4, 0)`, distance 3,
//     focus (0,0,0) (`view.d:206-208`, `viewport.d:911`), and `makeCube()` is
//     the eight vertices `+-0.5` about the origin. Focus, world `up` (0,1,0)
//     and the cube as a SET are all invariant under `R_y(PI/2)` ⇒ THE IMAGE IS
//     THE SAME. Both premise thresholds below therefore hold BY CONSTRUCTION,
//     not by luck: `d0` and `d1` are the same numbers they were before the
//     orbit.
//   * `R_y(PI/2): (x,y,z) -> (z,y,-x)` has a fixed point only where `x = z = 0`,
//     and no cube vertex is on the Y axis (all have |x| = |z| = 0.5). So the
//     index permutation has NO fixed vertex ⇒ `want != V` is guaranteed, not
//     hoped for.
//   * The vertex now in the parked pixel is the same FRONT vertex under a new
//     index, so the "nearest on screen is actually a REAR vertex the face
//     depth pre-pass throws away" hole (`occlusionTerm`,
//     `input_frame_state.d:395-397`) is closed by construction — and the
//     premise assert below re-checks it anyway by insisting `want` is the
//     camera-NEAREST vertex, which on a convex body is never occluded.
//
// ABSOLUTE, not `current + PI/2`: `/api/camera` publishes `azimuth` through
// `jsonNum(a, "%f")` (`view.d:655`), quantising to ~5e-7 rad. Reading it back
// and adding would carry that dust into the write. Posting the literal
// `0.5f + PI/2` never reads the published number at all. (The `azimuth` SETTER
// still round-trips elevation/roll through the chart for ~1e-7 rad — `view.d:
// 145-148` — which is ~1e-3 px against thresholds of 4 px and 40 px.)
//
// A PIXEL PROBE IS BLIND HERE BY CONSTRUCTION — the image after the orbit is
// the same image. So is a draw-call census, and so is `/api/frames/counts`:
// a stale slot and a fresh one make the same number of picks down the same
// path. The ONLY instrument that separates them is WHICH ELEMENT INDEX the ID
// buffer answers with. That is why this file reads `hover.vertex` and nothing
// else.
//
// Under the mutation the slot stays `valid` and `pick` reads the OLD FBO, so
// the answer is the OLD VERTEX — not `-1`. That matters: `-1` is also what a
// hover pass that stopped running reports, so a "hover goes empty" form would
// not discriminate.
//
// MUTATION (measured 2026-08-26): delete
//   `&& matricesEqual(slot.view, mv)` and `&& matricesEqual(slot.proj, vp.proj)`
// from `gpu_select.d :: ensureSlot` (`:486-487`) ->
//   `the parked hover reports vertex 6 after the camera orbited a quarter turn
//    about world Y. Vertex 2 is now 1.3 px from the cursor and the next nearest
//    is 107.3 px away, so 2 is the only answer the CURRENT camera can give
//    (6 was the answer BEFORE the orbit ...)`
// With the terms present: 6 -> 2.
//
// Runner: ./run_test.d test_gpu_select_slot_camera_key

import http_client : getJson, postRaw, testBaseUrl;
import std.net.curl : get, post;
import std.json;
import std.format : format;
import std.math   : sqrt, PI;
import std.conv   : to;
import core.thread : Thread;
import core.time   : dur;

import drag_helpers : fetchCamera, viewportFromCamera, projectToWindow,
                      playAndWait, CameraState, Vec3;

void main() {}

alias baseUrl = testBaseUrl;

/// POST and require the app to answer ok. The transport is the shared
/// client (tests/http_client.d); only the assertion is local.
void postOk(string path, string body_) {
    auto resp = postRaw(path, body_);
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

/// Index of the vertex nearest `(px,py)` on screen under camera `cam`, its
/// distance, and the distance of the SECOND nearest so the caller can insist
/// the answer is unambiguous.
void nearestOnScreen(JSONValue m, CameraState cam, int px, int py,
                     out int idx, out float d0, out float d1)
{
    auto vp = viewportFromCamera(cam);
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

/// The camera-NEAREST projectable vertex, and its pixel. On a convex body it
/// is never occluded, so it is pickable under any occlusion rule — the same
/// premise the `uploadVersion` sibling rests on.
void nearestToCamera(JSONValue m, CameraState cam,
                     out int idx, out float px, out float py)
{
    auto vp = viewportFromCamera(cam);
    idx = -1; px = 0; py = 0;
    float best = float.max;
    foreach (i; 0 .. m["vertices"].array.length) {
        Vec3 w = vertOf(m, i);
        Vec3 d = w - cam.eye;
        const float d2 = d.x * d.x + d.y * d.y + d.z * d.z;
        if (d2 >= best) continue;
        float sx, sy;
        if (!projectToWindow(w, vp, sx, sy)) continue;
        best = d2; idx = cast(int)i; px = sx; py = sy;
    }
    assert(idx >= 0, "no projectable cube vertex");
}

string parkAt(CameraState cam, int px, int py) {
    // Three motions at the same spot: the hover answer is recomputed by the
    // per-frame pass (`app.d:6584`), so one is enough in principle — the
    // repeats only make the park insensitive to which frame the player lands
    // the event in.
    return format(`{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
                  cam.vpX, cam.vpY, cam.width, cam.height)
         ~ format(`{"t":50.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n",
                  px, py)
         ~ format(`{"t":80.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n",
                  px, py)
         ~ format(`{"t":110.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n",
                  px, py);
}

unittest {
    postOk("/api/reset", "");
    settle();

    auto cam0 = fetchCamera();
    auto m0   = getJson("/api/model");

    int vid; float pxf, pyf;
    nearestToCamera(m0, cam0, vid, pxf, pyf);
    const int px = cast(int)pxf, py = cast(int)pyf;

    playAndWait(parkAt(cam0, px, py));
    settle();

    assert(hoverVertex() == vid,
        format("PREMISE: the cursor parked at (%d,%d) reports hover vertex %d, "
             ~ "expected %d — nothing below measures a STALE hover if the hover "
             ~ "never landed", px, py, hoverVertex(), vid));

    // Orbit a quarter turn about world Y. ABSOLUTE: the reset camera is
    // `fromAngles(0.5, 0.4, 0)`, so `0.5 + PI/2` is the quarter turn without
    // ever reading the `%f`-quantised published azimuth.
    postOk("/api/camera", format(`{"azimuth":%.9g}`, 0.5f + PI / 2));
    settle(600);

    // Re-park. Redundant (the hover pass re-picks every frame) but harmless,
    // and it makes the rig insensitive to which frame the camera write landed
    // in.
    auto cam1 = fetchCamera();
    playAndWait(parkAt(cam1, px, py));
    settle();

    int want; float d0, d1;
    nearestOnScreen(m0, cam1, px, py, want, d0, d1);

    int camNearest; float qx, qy;
    nearestToCamera(m0, cam1, camNearest, qx, qy);

    assert(want != vid,
        format("PREMISE: after the quarter turn the parked pixel is still "
             ~ "nearest to vertex %d — the orbit did not change WHICH vertex "
             ~ "is under the cursor, so a stale ID buffer and a fresh one "
             ~ "would agree", vid));
    assert(d0 < 4.0f && d1 > 40.0f,
        format("PREMISE: the parked pixel is %.1f px from vertex %d and %.1f px "
             ~ "from the next nearest — the answer must be unambiguous for the "
             ~ "pick radius (4 px, `input_frame_state.d:406`) or a miss/hit "
             ~ "says nothing", d0, want, d1));
    assert(want == camNearest,
        format("PREMISE: the vertex now under the cursor (%d) is not the "
             ~ "camera-nearest one (%d) — on a convex body only the "
             ~ "camera-nearest vertex is guaranteed unoccluded, so a rear "
             ~ "vertex here would be thrown away by the face depth pre-pass "
             ~ "and the test would redden on an UNTOUCHED tree", want, camNearest));

    const int got = hoverVertex();
    assert(got == want,
        format("the parked hover reports vertex %d after the camera orbited a "
             ~ "quarter turn about world Y. Vertex %d is now %.1f px from the "
             ~ "cursor and the next nearest is %.1f px away, so %d is the only "
             ~ "answer the CURRENT camera can give (%d was the answer BEFORE "
             ~ "the orbit — the picture is identical, only the indices moved). "
             ~ "The ID buffer was not re-rendered against the new view matrix "
             ~ "— `gpu_select`'s per-mode slot key no longer notices that the "
             ~ "camera moved",
               got, want, d0, d1, want, vid));

    postOk("/api/reset", "");
}
