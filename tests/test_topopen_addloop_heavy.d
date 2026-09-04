// Topology Pen P6 — addloop_heavy (item 8, doc/topopen_p6_addloop_plan.md
// "Testing Strategy": "heavy / scale case" — proves Δv=N/Δe=2N/Δf=N and
// spread=0 over a many-edge ring, the capture's 12-edge property).
//
// A closed N=12-sided quad belt (an open tube: two N-vertex rings, N side
// quads, no caps — 2N verts/3N edges/N faces) is loaded directly onto the
// PRIMARY layer (Add Loop never touches the background). A Shift+MMB click
// on one of the N vertical (side) edges must cut the FULL closed ring at a
// uniform r=0.5: Δv=+N/Δe=+2N/Δf=+N, and — the "spread=0" property the plan
// calls out — every one of the N crossed edges' new vertex must sit at its
// OWN exact midpoint (independently computed from the tube's own known
// parametric vertex coordinates), with no accumulated drift around the
// belt.
//
// Run via: ./run_test.d topopen_addloop_heavy

import http_command_helpers : commandBody;
import topopen_place_helpers;
import std.json;
import std.math   : cos, sin, PI;
import std.format : format;

void main() {}

enum uint LSHIFT = 0x0001;   // KMOD_LSHIFT — the Add Loop gesture's own modifier

/// An open tube (no caps): top ring [0..n) at y=+halfH, bottom ring
/// [n..2n) at y=-halfH, N side quads [top_i, top_{i+1}, bottom_{i+1},
/// bottom_i] — a closed belt of N quads, exactly like the cube's own
/// 4-face belt but with N sides instead of 4.
string tubeMeshBody(float radius, float halfH, int n) {
    assert(n >= 3, "degenerate tube resolution");

    Vec3[] verts;
    verts.length = 2 * n;
    foreach (i; 0 .. n) {
        float phi = 2.0f * PI * i / n;
        verts[i]     = Vec3(radius * cos(phi), halfH,  radius * sin(phi));   // top ring
        verts[n + i] = Vec3(radius * cos(phi), -halfH, radius * sin(phi));   // bottom ring
    }

    int[][] faces;
    foreach (i; 0 .. n) {
        int i1 = (i + 1) % n;
        faces ~= [i, i1, n + i1, n + i];
    }

    JSONValue[] vArr;
    foreach (v; verts)
        vArr ~= JSONValue([cast(double)v.x, cast(double)v.y, cast(double)v.z]);
    JSONValue[] fArr;
    foreach (f; faces) {
        JSONValue[] fi;
        foreach (idx; f) fi ~= JSONValue(idx);
        fArr ~= JSONValue(fi);
    }
    JSONValue j = JSONValue.emptyObject;
    j["vertices"] = JSONValue(vArr);
    j["faces"]    = JSONValue(fArr);
    return j.toString();
}

string shiftMmbClickAt(double t0, int px, int py) {
    return format(`{"t":%.3f,"type":"SDL_MOUSEBUTTONDOWN","btn":2,"x":%d,"y":%d,"clicks":1,"mod":%u}`,
                  t0, px, py, LSHIFT) ~ "\n"
         ~ format(`{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":2,"x":%d,"y":%d,"clicks":1,"mod":%u}`,
                  t0 + 10.0, px, py, LSHIFT);
}

unittest {
    enum int   N = 12;
    enum float R = 1.0f;
    enum float H = 0.5f;

    postJson("/api/reset", "");
    auto lr = postJson("/api/command", commandBody("scene.loadMesh", tubeMeshBody(R, H, N)));
    assert(lr["status"].str == "ok", "load-mesh (tube) failed: " ~ lr.toString);

    postJson("/api/camera", format(
        `{"azimuth":%.6f,"elevation":%.6f,"distance":%.6f,"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`,
        0.3, 0.5, 4.0, 0.0, 0.0, 0.0));

    auto c  = fetchCamera();
    auto vp = viewportFromCamera(c);

    assert(vertexCountLayer(0) == 2 * N && faceCountLayer(0) == N,
        "setup: pre-state must be the untouched N-sided tube");
    assert(edgeCountLayer(0) == 3 * N,
        "setup: tube must have 3N edges (N vertical + N top-rim + N bottom-rim)");

    // Seed = vertical edge 0: top_0=(R,H,0), bottom_0=(R,-H,0); its own
    // midpoint = (R,0,0).
    float sx, sy;
    assert(projectToWindow(Vec3(R, 0.0f, 0.0f), vp, sx, sy),
        "seed vertical edge's midpoint must project on-screen");

    cmd("tool.set mesh.topoPen on");

    string log = viewportLog(c.vpX, c.vpY, c.width, c.height) ~ "\n"
               ~ shiftMmbClickAt(10.0, cast(int)sx, cast(int)sy) ~ "\n";
    auto pr = postJson("/api/play-events", log);
    assert("error" !in pr, "/api/play-events failed: " ~ pr.toString);
    waitPlayerIdle();

    assert(vertexCountLayer(0) == 2 * N + N,
        format("heavy N=%d ring cut must add exactly N vertices; got %d", N, vertexCountLayer(0)));
    assert(edgeCountLayer(0) == 3 * N + 2 * N,
        format("heavy N=%d ring cut must add exactly 2N edges; got %d", N, edgeCountLayer(0)));
    assert(faceCountLayer(0) == N + N,
        format("heavy N=%d ring cut must add exactly N faces; got %d", N, faceCountLayer(0)));

    // Spread=0: EVERY one of the N crossed edges' new vertex sits at its own
    // exact midpoint — independently computed from the tube's own known
    // parametric coordinates, never from the tool's own output.
    enum double eps = 5e-2;   // camera-ray/click-pixel derived, looser than the exact-click cube fixtures
    foreach (i; 0 .. N) {
        float phi = 2.0f * PI * i / N;
        Vec3 expectedMid = Vec3(R * cos(phi), 0.0f, R * sin(phi));
        assert(hasVertexNear(0, expectedMid, eps),
            format("crossed edge %d's new vertex must sit at its own midpoint "
                 ~ "(uniform ratio / spread=0 around the %d-edge ring)", i, N));
    }
}
