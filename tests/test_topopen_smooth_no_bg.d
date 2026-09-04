// Topology Pen P8 — smooth_no_bg (T6/T7, doc/topopen_p8_smooth_plan.md
// "Testing Strategy").
//
// T6: with NO background layer at all, Shift+Ctrl+LMB still relaxes a
// CONNECTED primary patch (no crash, no re-snap possible — nothing to
// constrain to — topology unchanged) — the graceful degrade the plan
// documents.
//
// T7 (REV1 FIX-2): a Smooth gesture over a fully DISCONNECTED patch (every
// vertex has 0 neighbors) with no background source is the ROUTINE no-op
// case — the mesh must be byte-identical and record NO undo entry
// (mirrors test_topopen_move_stationary_noop.d's own undo-depth check).
//
// Run via: ./run_test.d topopen_smooth_no_bg

import http_command_helpers : commandBody;
import topopen_place_helpers;
import std.json;
import std.format : format;

void main() {}

enum uint SHIFT_CTRL = 0x0001 | 0x0040;   // KMOD_LSHIFT | KMOD_LCTRL

Vec3 toVec3(double[3] v) { return Vec3(cast(float)v[0], cast(float)v[1], cast(float)v[2]); }

bool vecApproxEq(Vec3 a, Vec3 b, float eps) {
    Vec3 d = a - b;
    return dot(d, d) < eps * eps;
}

string trianglePatchBody(Vec3 a, Vec3 b, Vec3 c) {
    return format(
        `{"vertices":[[%.6f,%.6f,%.6f],[%.6f,%.6f,%.6f],[%.6f,%.6f,%.6f]],"faces":[[0,1,2]]}`,
        a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z);
}

string disconnectedPointsBody() {
    // 3 isolated points, NO faces (and hence no derived edges) -> every
    // vertex has 0 neighbors.
    return `{"vertices":[[0,0,0],[5,0,0],[0,5,0]],"faces":[]}`;
}

unittest {
    // --- T6: connected patch, no background layer -> graceful relax ---
    {
        postJson("/api/command", commandBody("scene.reset"));   // single layer == primary (layer 0), no background

        Vec3 A = Vec3(1, 0, 0);
        Vec3 C = Vec3(0, 0, 1);
        Vec3 B = Vec3(0, 10, 0);   // far from the mean of A/C -> relax must visibly move it

        auto lr = postJson("/api/command", commandBody("scene.loadMesh", trianglePatchBody(A, B, C)));
        assert(lr["status"].str == "ok", "load-mesh (triangle patch) failed: " ~ lr.toString);
        assert(vertexCountLayer(0) == 3 && edgeCountLayer(0) == 3 && faceCountLayer(0) == 1,
            "setup: primary layer must be the untouched 1-triangle patch, no bg layer exists");

        postJson("/api/camera", format(
            `{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
            0.3, 0.5, 8.0, 0.0, 0.0, 0.0));
        auto c = fetchCamera();
        int cx = c.vpX + c.width / 2, cy = c.vpY + c.height / 2;

        cmd("tool.set mesh.topoPen on");

        auto pr = postJson("/api/play-events",
            buildDragLog(c.vpX, c.vpY, c.width, c.height, cx, cy, cx, cy, 0, SHIFT_CTRL, 1));
        assert("error" !in pr, "/api/play-events failed (no-bg Smooth must not crash): " ~ pr.toString);
        waitPlayerIdle();

        assert(vertexCountLayer(0) == 3 && edgeCountLayer(0) == 3 && faceCountLayer(0) == 1,
            "Smooth must never change topology, even with no background (zero delta)");

        auto post = readVerticesLayer(0);
        Vec3 bAfter = toVec3(post[1]);
        assert(!vecApproxEq(bAfter, B, 1e-3f),
            "the connected patch must have genuinely relaxed (no bg to re-snap against, "
          ~ "but relaxation itself still applies)");
    }

    // --- T7: fully disconnected patch, no background layer -> byte-identical no-op ---
    {
        postJson("/api/command", commandBody("scene.reset"));

        auto lr = postJson("/api/command", commandBody("scene.loadMesh", disconnectedPointsBody()));
        assert(lr["status"].str == "ok", "load-mesh (disconnected points) failed: " ~ lr.toString);
        assert(vertexCountLayer(0) == 3 && edgeCountLayer(0) == 0 && faceCountLayer(0) == 0,
            "setup: primary layer must be 3 isolated points with NO edges");

        postJson("/api/camera", format(
            `{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
            0.3, 0.5, 8.0, 0.0, 0.0, 0.0));
        auto c = fetchCamera();
        int cx = c.vpX + c.width / 2, cy = c.vpY + c.height / 2;

        cmd("tool.set mesh.topoPen on");

        auto pre = readVerticesLayer(0);
        int undoDepthBefore = cast(int) getJson("/api/history")["undo"].array.length;

        auto pr = postJson("/api/play-events",
            buildDragLog(c.vpX, c.vpY, c.width, c.height, cx, cy, cx, cy, 0, SHIFT_CTRL, 1));
        assert("error" !in pr, "/api/play-events failed: " ~ pr.toString);
        waitPlayerIdle();

        assert(vertexCountLayer(0) == 3 && edgeCountLayer(0) == 0 && faceCountLayer(0) == 0,
            "T7: topology must stay unchanged");

        auto post = readVerticesLayer(0);
        assert(post == pre,
            "T7: a disconnected patch with no background source must be a BYTE-IDENTICAL no-op");

        int undoDepthAfter = cast(int) getJson("/api/history")["undo"].array.length;
        assert(undoDepthAfter == undoDepthBefore,
            format("T7: a disconnected/no-bg Smooth gesture must record NO undo entry; "
                 ~ "undo depth went %d -> %d", undoDepthBefore, undoDepthAfter));
    }
}
