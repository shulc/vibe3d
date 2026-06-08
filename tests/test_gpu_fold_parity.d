// Apply-path unification Phase 3 — GPU/CPU fast-path parity for the
// COMPOSED-FOLD Move drag.
//
// The transform Move fast-path draws the whole-mesh drag with a single GPU
// u_model matrix instead of re-uploading the vertex buffer every frame. The
// renderer's true on-screen pose is therefore `gpuMatrix · gpu.faceVbo`, and
// the CPU mesh (/api/model) must agree with it mid-drag.
//
// Two cases:
//
//   (1) SINGLE-BANK Move (Move preset, no held R/S). The fold matrix is a pure
//       translation, and the fast-path keeps the cheap
//       `translationMatrix(accumulatedWorldDelta)` (byte-identical to the
//       pre-Phase-3 code: a translation is invariant under wrapAboutPivot). We
//       assert `gpuMatrix · faceVbo` == CPU mesh AND that `gpuMatrix` is a pure
//       translation (rotation/scale block == identity 3×3) — the proxy that the
//       common path did NOT switch to the composed branch.
//
//   (2) CROSS-BANK Rotate-then-Move (Transform preset, T+R+S all on). Commit a
//       rotate ring drag, then start a Move arrow drag with NO mouse-up. Under
//       Phase-2 routing the Move drag reuses the run baseline and the held
//       rotate survives into `composeFor`, so the CPU mesh holds the full T·R.
//
//       Phase 3 chose plan option (b): the committed rotate's mouse-up did
//       `gpu.upload(*mesh)`, so the GPU buffer is the ALREADY-ROTATED mesh, NOT
//       the fold's run baseline. The published `lastFoldMatrix` is composed
//       RELATIVE to the baseline, so `wrapAboutPivot(lastFoldMatrix) · buffer`
//       would re-apply the rotate a SECOND time (double transform). So the Move
//       fast-path DROPS OUT when a held R/S is non-identity: it re-uploads the
//       CPU-folded verts and keeps `gpuMatrix` at identity. We assert
//       `gpuMatrix · faceVbo` == CPU mesh mid-drag (here trivially, since the
//       VBO == CPU mesh and u_model == identity).
//
//       BEFORE the Phase-3 fix this case FAILS: the Move fast-path drew
//       `translationMatrix(delta)` on the UN-rotated baseline buffer, so the GPU
//       preview dropped the held rotate and diverged from the CPU verts until
//       mouseUp's re-upload. This is the matrix-value parity proxy the plan
//       calls for — full pixel readback is unnecessary because the endpoint
//       returns BOTH the raw VBO and the exact u_model the renderer applies.
//
// All gestures drive the MAIN loop via drag_helpers (real event playback), so
// the fast-path predicate is exercised end-to-end, not poked directly.

import std.net.curl;
import std.json;
import std.math : fabs, sqrt, sin, cos, PI;
import std.conv : to;
import std.format : format;

import drag_helpers;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string)post(baseUrl ~ path, body_));
}
JSONValue getJson(string path) {
    return parseJSON(cast(string)get(baseUrl ~ path));
}

bool approx(double a, double b, double eps = 1e-3) { return fabs(a - b) < eps; }

// Multiply a 16-element column-major matrix by a (x,y,z,1) point.
double[3] applyModel(double[16] m, double x, double y, double z) {
    double rx = m[0]*x + m[4]*y + m[8]*z  + m[12];
    double ry = m[1]*x + m[5]*y + m[9]*z  + m[13];
    double rz = m[2]*x + m[6]*y + m[10]*z + m[14];
    return [rx, ry, rz];
}

// One tool-session drag, with optional trailing mouse-up so the caller can
// leave the tool mid-drag (release=false) and read the GPU u_model in flight.
string buildPartialDragLog(int vpX, int vpY, int vpW, int vpH,
                           int x0, int y0, int x1, int y1,
                           int steps, bool release, double tStart = 50.0)
{
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        vpX, vpY, vpW, vpH);
    log ~= format(
        `{"t":%.3f,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        tStart, x0, y0);
    double stepMs = 50.0;
    int lastX = x0, lastY = y0;
    foreach (i; 1 .. steps + 1) {
        int x = x0 + cast(int)((cast(double)(x1 - x0) * i) / steps);
        int y = y0 + cast(int)((cast(double)(y1 - y0) * i) / steps);
        double t = tStart + i * stepMs;
        log ~= format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":1,"mod":0}` ~ "\n",
            t, x, y, x - lastX, y - lastY);
        lastX = x; lastY = y;
    }
    if (release) {
        double tUp = tStart + (steps + 1) * stepMs;
        log ~= format(
            `{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
            tUp, x1, y1);
    }
    return log;
}

void waitPlaybackFinish() {
    import core.thread : Thread;
    import core.time   : msecs;
    foreach (_; 0 .. 200) {
        auto j = getJson("/api/play-events/status");
        if (j["finished"].type == JSONType.TRUE) return;
        Thread.sleep(50.msecs);
    }
    assert(false, "playback didn't finish within 10s");
}

// Assert the GPU on-screen pose (`model · faceVbo`) matches the CPU mesh.
// Each unique cube vert appears many times in the face VBO; for every
// face-vert we just require the transformed GPU position to coincide with SOME
// CPU vert within tol (the mesh is a cube — 8 distinct corners).
void assertGpuMatchesCpu(string ctx, double tol = 1e-3) {
    auto cpu = getJson("/api/model")["vertices"].array;
    auto gpu = getJson("/api/gpu/face-vbo");
    auto m   = gpu["model"].array;
    double[16] model;
    foreach (i; 0 .. 16) model[i] = m[i].floating;
    auto positions = gpu["positions"].array;
    long faceVerts = gpu["faceVertCount"].integer;
    assert(faceVerts > 0, ctx ~ ": GPU has no face verts");
    foreach (i; 0 .. faceVerts) {
        auto p = positions[i].array;
        auto visual = applyModel(model,
            p[0].floating, p[1].floating, p[2].floating);
        double bestD2 = double.max;
        foreach (v; cpu) {
            double dx = v.array[0].floating - visual[0];
            double dy = v.array[1].floating - visual[1];
            double dz = v.array[2].floating - visual[2];
            double d2 = dx*dx + dy*dy + dz*dz;
            if (d2 < bestD2) bestD2 = d2;
        }
        assert(bestD2 < tol*tol,
            ctx ~ ": GPU-rendered face-vert " ~ i.to!string ~ " = (" ~
            visual[0].to!string ~ "," ~ visual[1].to!string ~ "," ~
            visual[2].to!string ~ ") matches no CPU vert within " ~
            tol.to!string ~ " (closest d²=" ~ bestD2.to!string ~ "). The GPU " ~
            "u_model dropped a held bank — Move fast-path drew translate-only " ~
            "on a composed-fold run.");
    }
}

// X-ring (normal +X, YZ plane) grab pixel at a screen angle on the visible
// semicircle for the default test camera (110° — proven hittable in
// test_relocate_boundary_rs.d).
void ringGrabPx(Vec3 pivot, ref Viewport vp, out int gx, out int gy) {
    float size = gizmoSize(pivot, vp);
    float a = 110.0f * cast(float)PI / 180.0f;
    Vec3 p = Vec3(pivot.x, pivot.y + cos(a) * size, pivot.z + sin(a) * size);
    float sx, sy;
    projectToWindow(p, vp, sx, sy);
    gx = cast(int)sx; gy = cast(int)sy;
}

// +X arrow grab pixel + screen-space +X direction (for a Move drag along X).
void axisGrabPx(Vec3 pivot, ref Viewport vp, out int gx, out int gy,
                out double ux, out double uy) {
    float size = gizmoSize(pivot, vp);
    float sx1, sy1, sx2, sy2;
    projectToWindow(Vec3(pivot.x + size / 7.0f,  pivot.y, pivot.z), vp, sx1, sy1);
    projectToWindow(Vec3(pivot.x + size * 1.18f, pivot.y, pivot.z), vp, sx2, sy2);
    gx = cast(int)(sx1 + 0.7f * (sx2 - sx1));
    gy = cast(int)(sy1 + 0.7f * (sy2 - sy1));
    double dx = sx2 - sx1, dy = sy2 - sy1;
    double len = sqrt(dx*dx + dy*dy);
    ux = dx / len; uy = dy / len;
}

// ---------------------------------------------------------------------------
// (1) SINGLE-BANK Move — fast-path stays the cheap pure-translation matrix,
//     byte-identical to pre-Phase-3.
// ---------------------------------------------------------------------------
unittest {
    postJson("/api/reset", "");
    // No selection ⇒ whole-mesh moving set, pivot at origin (fast-path eligible).
    postJson("/api/script", "tool.set move");

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);

    Vec3 pivot = Vec3(0, 0, 0);
    int gx, gy; double ux, uy;
    axisGrabPx(pivot, vp, gx, gy, ux, uy);
    int x1 = gx + cast(int)(60.0 * ux);
    int y1 = gy + cast(int)(60.0 * uy);

    // No mouse-up: leave the tool mid-drag so the GPU u_model is live.
    auto log = buildPartialDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                   gx, gy, x1, y1, 10, /*release=*/false);
    auto r = postJson("/api/play-events", log);
    assert(r["status"].str == "success", "single-bank move play-events failed");
    waitPlaybackFinish();

    // The u_model the renderer applies must be a PURE translation — the cheap
    // branch, not the composed-fold wrapAboutPivot. (3×3 block == identity.)
    auto gpu = getJson("/api/gpu/face-vbo");
    auto m   = gpu["model"].array;
    double[9] rot = [m[0].floating, m[1].floating, m[2].floating,
                     m[4].floating, m[5].floating, m[6].floating,
                     m[8].floating, m[9].floating, m[10].floating];
    double[9] ident = [1,0,0, 0,1,0, 0,0,1];
    foreach (i; 0 .. 9)
        assert(approx(rot[i], ident[i], 1e-5),
            "single-bank Move u_model should be a pure translation (3×3 == I); " ~
            "block[" ~ i.to!string ~ "]=" ~ rot[i].to!string ~
            " — the fast-path took the composed branch for a single-bank drag.");
    // And the translate column must be non-zero (the drag actually moved).
    double tlen = sqrt(m[12].floating*m[12].floating
                     + m[13].floating*m[13].floating
                     + m[14].floating*m[14].floating);
    assert(tlen > 1e-4, "single-bank Move produced no translation");

    // GPU pose == CPU mesh.
    assertGpuMatchesCpu("single-bank move");

    postJson("/api/script", "tool.set move off");
}

// ---------------------------------------------------------------------------
// (2) CROSS-BANK Rotate-then-Move — the Phase-3 fix. Held rotate must survive
//     into the GPU u_model during the Move drag.
// ---------------------------------------------------------------------------
unittest {
    postJson("/api/reset", "");
    // Composed preset, default ACEN = None (pivot at origin for whole-mesh).
    postJson("/api/script", "tool.set Transform");

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);
    Vec3 pivot = Vec3(0, 0, 0);

    // ---- Rotate ring drag, COMMITTED (release=true) -----------------------
    int rgx, rgy;
    ringGrabPx(pivot, vp, rgx, rgy);
    auto rotLog = buildPartialDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                      rgx, rgy, rgx + 25, rgy + 25, 10,
                                      /*release=*/true);
    auto rr = postJson("/api/play-events", rotLog);
    assert(rr["status"].str == "success", "rotate ring play-events failed");
    waitPlaybackFinish();

    // The rotate must have actually rotated the mesh (a cube corner left its
    // axis-aligned position). Otherwise the cross-bank case is vacuous.
    auto cpuAfterRot = getJson("/api/model")["vertices"].array;
    bool rotated = false;
    foreach (v; cpuAfterRot) {
        double x = v.array[0].floating, y = v.array[1].floating,
               z = v.array[2].floating;
        // A unit cube corner is (±a,±a,±a); after a YZ-plane rotation about +X
        // the |y| or |z| of at least one corner departs from its sibling.
        if (fabs(fabs(y) - fabs(z)) > 0.05) { rotated = true; break; }
    }
    assert(rotated, "rotate ring drag did not rotate the mesh — cross-bank "
        ~ "case would be vacuous (held rotate is identity).");

    // After mouse-up the GPU was re-uploaded with the rotated mesh and the
    // u_model reset to identity — CPU and GPU agree here.
    assertGpuMatchesCpu("after committed rotate");

    // ---- Move arrow drag, mid-flight (NO mouse-up) ------------------------
    // Re-fetch the camera/pivot; the gizmo pivot is still the origin (ACEN=None,
    // whole mesh). Grab the +X arrow and drag.
    auto cam2 = fetchCamera();
    auto vp2  = viewportFromCamera(cam2);
    int gx, gy; double ux, uy;
    axisGrabPx(pivot, vp2, gx, gy, ux, uy);
    int x1 = gx + cast(int)(60.0 * ux);
    int y1 = gy + cast(int)(60.0 * uy);
    auto moveLog = buildPartialDragLog(cam2.vpX, cam2.vpY, cam2.width, cam2.height,
                                       gx, gy, x1, y1, 10, /*release=*/false);
    auto mr = postJson("/api/play-events", moveLog);
    assert(mr["status"].str == "success", "cross-bank move play-events failed");
    waitPlaybackFinish();

    // The CPU mesh now holds the full T·R (held rotate composed with the live
    // translate via the fold). Phase 3 chose plan option (b): because the held
    // rotate's mouse-up re-uploaded the rotated mesh into the VBO (so the GPU
    // buffer is NO LONGER the fold's run baseline), the Move fast-path cannot
    // safely reuse `wrapAboutPivot(lastFoldMatrix)` — multiplying the
    // already-rotated buffer by the composed S·R·T would double-apply the
    // rotate. Instead it DROPS OUT of the fast-path: it re-uploads the CPU-folded
    // verts and leaves `gpuMatrix` at identity. So `model · faceVbo` matches the
    // CPU mesh because the VBO IS the CPU mesh and the model matrix is identity.
    //
    // Pre-Phase-3 the Move fast-path drew `translationMatrix(delta)` on the
    // un-rotated baseline buffer (dropping the held rotate) and this diverged —
    // this assert is the regression guard.
    assertGpuMatchesCpu("cross-bank rotate-then-move (Phase-3 CPU fallback)");

    // Sanity: option (b) fell to the CPU upload, so the GPU u_model is IDENTITY
    // (the held rotate lives in the re-uploaded VBO, not in u_model). This is
    // the testable proxy that the cross-bank case took the safe CPU path rather
    // than the byte-identical single-bank translate fast-path.
    auto gpu = getJson("/api/gpu/face-vbo");
    auto m   = gpu["model"].array;
    foreach (i; 0 .. 16) {
        double expected = (i == 0 || i == 5 || i == 10 || i == 15) ? 1.0 : 0.0;
        assert(approx(m[i].floating, expected, 1e-5),
            "cross-bank Move u_model should be IDENTITY (option-(b) CPU "
            ~ "fallback); model[" ~ i.to!string ~ "]=" ~ m[i].floating.to!string
            ~ " — the fast-path did NOT drop out for a held-rotate run.");
    }

    postJson("/api/script", "tool.set Transform off");
}
