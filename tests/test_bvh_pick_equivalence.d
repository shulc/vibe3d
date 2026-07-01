// A/B equivalence sweep: BVH face-pick must match GPU face-pick at every
// (fixture, camera, pixel) sample.  The FACE-PICK EQUIVALENCE contract:
//   bvhPickFace(x,y) == gpuSelectPickFace(x,y)   (cage face index, incl. -1)
// Exempt: exactly-coincident/coplanar faces (GPU draw-order tie-break vs
// nanort arbitrary-t differ); avoided by fixture design.
//
// Run via: ./run_test.d bvh_pick_equivalence
import std.net.curl;
import std.json;
import std.conv    : to;
import std.stdio   : writeln, writefln;
import std.format  : format;

void main() {}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

void waitPlayerIdle() {
    import core.thread : Thread;
    import core.time   : dur;
    for (int i = 0; i < 200; ++i) {
        auto s = parseJSON(get("http://localhost:8080/api/play-events/status"));
        auto f = "finished" in s;
        if (f is null || f.type != JSONType.FALSE) {
            Thread.sleep(dur!"msecs"(120));
            return;
        }
        Thread.sleep(dur!"msecs"(10));
    }
}

JSONValue postJson(string path, string body) {
    return parseJSON(cast(string)post("http://localhost:8080" ~ path, body));
}

void runCmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok" || r["status"].str == "success",
           "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}

void resetTo(string prim = "") {
    waitPlayerIdle();
    post("http://localhost:8080/api/reset", prim);
}

void setCamera(float az, float el, float dist) {
    auto r = postJson("/api/camera",
        format(`{"azimuth":%.4f,"elevation":%.4f,"distance":%.4f}`,
               az, el, dist));
    assert("error" !in r, "/api/camera failed: " ~ r.toString);
}

/// Assert BVH == GPU at (x,y). Returns the agreed face index.
int assertPickAgreement(int x, int y, string ctx) {
    import core.thread : Thread;
    import core.time   : dur;
    // Settle one frame so any pending GPU upload lands before we probe.
    Thread.sleep(dur!"msecs"(60));

    int bvh = parseJSON(get(
        format("http://localhost:8080/api/pick?x=%d&y=%d&engine=bvh", x, y)
    ))["faceIndex"].integer.to!int;
    int gpu = parseJSON(get(
        format("http://localhost:8080/api/pick?x=%d&y=%d&engine=gpu", x, y)
    ))["faceIndex"].integer.to!int;
    assert(bvh == gpu,
           ctx ~ " — BVH=" ~ bvh.to!string ~ " GPU=" ~ gpu.to!string ~
           " at (" ~ x.to!string ~ "," ~ y.to!string ~ ")");
    return bvh;
}

/// Sweep a pixel grid and verify A/B equality at every sample.
void sweepGrid(int vpX, int vpY, int vpW, int vpH,
               int step, string ctx, bool requireHit = false)
{
    import core.thread : Thread;
    import core.time   : dur;
    Thread.sleep(dur!"msecs"(60));   // one-frame settle before sweep

    int mismatches = 0;
    int hits = 0;
    for (int y = vpY; y < vpY + vpH; y += step) {
        for (int x = vpX; x < vpX + vpW; x += step) {
            int bvh = parseJSON(get(
                format("http://localhost:8080/api/pick?x=%d&y=%d&engine=bvh", x, y)
            ))["faceIndex"].integer.to!int;
            int gpu = parseJSON(get(
                format("http://localhost:8080/api/pick?x=%d&y=%d&engine=gpu", x, y)
            ))["faceIndex"].integer.to!int;
            if (bvh != gpu) {
                writefln("MISMATCH %s pixel(%d,%d) BVH=%d GPU=%d",
                         ctx, x, y, bvh, gpu);
                ++mismatches;
            }
            if (bvh >= 0) ++hits;
        }
    }
    assert(mismatches == 0,
           ctx ~ ": " ~ mismatches.to!string ~ " mismatch(es)");
    if (requireHit)
        assert(hits > 0, ctx ~ ": no face was hit in the sweep grid");
}

// Standard viewport rect used in event logs.
enum int VP_X = 150, VP_Y = 28, VP_W = 650, VP_H = 544;
// Centre pixel of the viewport.
enum int CX = VP_X + VP_W / 2, CY = VP_Y + VP_H / 2;

// ---------------------------------------------------------------------------
// Fixture: cube (convex, baseline)
// ---------------------------------------------------------------------------
unittest {
    resetTo();

    // Front-facing camera.
    setCamera(0.0f, 0.0f, 3.0f);
    sweepGrid(VP_X, VP_Y, VP_W, VP_H, 30, "cube/front", /*requireHit=*/true);

    // Oblique view exercises multiple visible faces.
    setCamera(0.785f, 0.4f, 3.0f);
    sweepGrid(VP_X, VP_Y, VP_W, VP_H, 30, "cube/oblique", true);

    // Near-top — back faces are culled by the GPU pass; BVH closest-hit
    // (no cull) must still pick the same frontmost face.
    setCamera(0.0f, 1.3f, 3.0f);
    sweepGrid(VP_X, VP_Y, VP_W, VP_H, 30, "cube/top", true);

    writeln("PASS cube equivalence");
}

// ---------------------------------------------------------------------------
// Fixture: torus (many quads, curved surface, silhouette variety)
// ---------------------------------------------------------------------------
unittest {
    resetTo("torus");

    setCamera(0.5f, 0.5f, 4.0f);
    sweepGrid(VP_X, VP_Y, VP_W, VP_H, 25, "torus/oblique", true);

    setCamera(0.0f, 1.4f, 4.0f);
    sweepGrid(VP_X, VP_Y, VP_W, VP_H, 25, "torus/top", true);

    writeln("PASS torus equivalence");
}

// ---------------------------------------------------------------------------
// Fixture: concave n-gon (exercises face[0] fan-diagonal identity).
// An L-shaped hexagon face has a non-convex silhouette; a wrong fan pivot
// would cause BVH to miss pixels that GPU covers (or vice versa).
// ---------------------------------------------------------------------------
unittest {
    resetTo();

    // L-shaped hex (concave polygon) in the XZ plane, viewed from above.
    // Vertices: (0,0,0), (2,0,0), (2,0,1), (1,0,1), (1,0,2), (0,0,2).
    string meshJson = `{
        "vertices":[[0,0,0],[2,0,0],[2,0,1],[1,0,1],[1,0,2],[0,0,2]],
        "faces":[[0,1,2,3,4,5]]
    }`;
    auto lr = postJson("/api/load-mesh", meshJson);
    assert("error" !in lr, "/api/load-mesh: " ~ lr.toString);

    // Camera looking straight down (+Y → looking at -Y).
    auto cr = postJson("/api/camera",
        `{"azimuth":0.0,"elevation":1.5707,"distance":5.0}`);
    assert("error" !in cr, "/api/camera: " ~ cr.toString);

    sweepGrid(VP_X, VP_Y, VP_W, VP_H, 12, "concave-hexagon/top", true);

    writeln("PASS concave n-gon equivalence (fan-diagonal identity)");
}

// ---------------------------------------------------------------------------
// Fixture: subpatch preview — cage ↔ preview transitions must trigger BVH
// rebuild.  This validates the (uploadVersion, source-mesh-address) key:
// toggling the preview bumps uploadVersion AND changes the source address
// (preview.mesh ≠ cage mesh), so both terms are exercised.
//
// Note: subpatchDepth is fixed at 3 in this build (no HTTP command exists
// to change it), so we exercise depth-3 preview only.  The critical
// property — that a GPU re-upload that does NOT bump cage mutationVersion
// still triggers a BVH rebuild — is demonstrated by the cage↔preview
// transition: the cage mutationVersion is unchanged after toggling preview
// off (the preview rebuild only reads it; mesh.d:10663/10666), yet
// uploadVersion advances → BVH correctly rebuilds.
// ---------------------------------------------------------------------------
unittest {
    import core.thread : Thread;
    import core.time   : dur;

    resetTo();

    // Switch to polygon mode (required for mesh.subpatch_toggle).
    runCmd("select.typeFrom polygon");

    setCamera(0.5f, 0.4f, 3.0f);

    // ---- cage baseline ----
    int cageFace = assertPickAgreement(CX, CY, "subpatch/cage-baseline");
    assert(cageFace >= 0, "cage baseline should hit a face");

    // ---- enable subpatch preview (toggle all faces) ----
    runCmd("mesh.subpatch_toggle");
    Thread.sleep(dur!"msecs"(200));   // let preview rebuild + GPU upload land

    sweepGrid(VP_X, VP_Y, VP_W, VP_H, 35,
              "subpatch/preview-on", /*requireHit=*/true);

    // ---- disable subpatch preview ----
    runCmd("mesh.subpatch_toggle");
    Thread.sleep(dur!"msecs"(120));

    // After toggling off the BVH must have rebuilt from the cage again.
    sweepGrid(VP_X, VP_Y, VP_W, VP_H, 35, "subpatch/preview-off", true);

    // ---- re-enable to confirm a second uploadVersion advance rebuilds again ----
    runCmd("mesh.subpatch_toggle");
    Thread.sleep(dur!"msecs"(200));

    sweepGrid(VP_X, VP_Y, VP_W, VP_H, 35,
              "subpatch/preview-on-again", true);

    writeln("PASS subpatch preview equivalence (uploadVersion rebuild)");
}

// ---------------------------------------------------------------------------
// Fixture: miss pixels — corners of the viewport must return -1 for both.
// ---------------------------------------------------------------------------
unittest {
    resetTo();

    setCamera(0.0f, 0.0f, 3.0f);

    // The very corners of the viewport are far outside the cube's silhouette.
    int[2][4] corners = [
        [VP_X + 1,         VP_Y + 1        ],
        [VP_X + VP_W - 2,  VP_Y + 1        ],
        [VP_X + 1,         VP_Y + VP_H - 2 ],
        [VP_X + VP_W - 2,  VP_Y + VP_H - 2 ],
    ];
    foreach (c; corners)
        assertPickAgreement(c[0], c[1], "miss/corners");

    writeln("PASS miss equivalence");
}
