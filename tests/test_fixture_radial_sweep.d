// test_fixture_radial_sweep.d — golden parity fixture for the interactive
// Radial Sweep tool's Count-semantics translation (task 0326).
//
// Reference measurement (toolcards/radial_sweep, task 0326 discriminating
// capture, private repo -- NOT re-derived here, only the MEASURED delta is
// pinned as this fixture's golden): a unit cube's edge
// (0.5,-0.5,-0.5)-(0.5,0.5,-0.5) (open 2-vertex profile, constant radius
// sqrt(0.5) from the Y axis through the origin) swept with reference
// Count=4, Start Angle=0deg, End Angle=180deg, no caps -> measured
// +8 vertices / +4 faces (toolcard capture/count_semantics_summary.json,
// case `discriminator_open4_nocap`). This is the "B" (new-BANDS)
// hypothesis: ring count = Count+1 = 5 for a non-closed sweep -- a literal
// count->sides port (the "A", total-copies reading -- vibe3d's `mesh.sweep`
// `count` param's OWN pre-existing convention) would instead predict
// +6v/+3f and is asserted below as the WRONG answer this fixture guards
// against silently regressing to.
//
// No external reference engine at runtime: this is a direct-import D
// unittest exercising RadialSweepTool's pure translation functions
// (RadialSweepParams / toKernelParams) and Mesh.revolveProfileEx directly
// -- no HTTP server, no live vibe3d instance, no GL context required.

import std.conv : to;
import std.math : abs, sin, cos, PI;
import mesh;
import math : Vec3;
import tools.radial_sweep_tool;

void main() {}

private bool closeVec(Vec3 a, Vec3 b, float eps = 1e-4f) {
    return abs(a.x - b.x) < eps && abs(a.y - b.y) < eps && abs(a.z - b.z) < eps;
}

// ---------------------------------------------------------------------------
// Primary golden case: Count=4, 0deg -> 180deg, no caps -> +8v/+4f.
// ---------------------------------------------------------------------------
unittest {
    Mesh m = makeCube();
    // Edge {1,2}: vert1=(0.5,-0.5,-0.5), vert2=(0.5,0.5,-0.5) -- the exact
    // edge the toolcard's discriminating capture used (an interior cube
    // edge at constant radius sqrt(0.5) from the Y axis through the
    // origin). Hand-built profile array (same style as revolveProfile's
    // own unittests in mesh.d), not routed through selection/extraction --
    // this fixture is about the Count-semantics TRANSLATION + rotation
    // law, not edge-chain extraction (covered elsewhere).
    immutable uint v1 = 1, v2 = 2;
    Vec3 p1 = m.vertices[v1];
    Vec3 p2 = m.vertices[v2];
    assert(p1 == Vec3(0.5f, -0.5f, -0.5f), "test setup: unexpected makeCube layout for vert " ~ v1.to!string);
    assert(p2 == Vec3(0.5f,  0.5f, -0.5f), "test setup: unexpected makeCube layout for vert " ~ v2.to!string);

    size_t vertsBefore = m.vertices.length;
    size_t facesBefore = m.faces.length;

    RadialSweepParams rp;
    rp.sides         = 4;              // reference "Count" (NEW-BANDS convention)
    rp.axisPreset    = 1;              // Y
    rp.axis          = Vec3(0, 1, 0);
    rp.center        = Vec3(0, 0, 0);
    rp.startAngleDeg = 0.0f;
    rp.endAngleDeg   = 180.0f;
    rp.offset        = 0.0f;
    rp.cap0          = false;
    rp.cap1          = false;

    auto kp = toKernelParams(rp);
    // The measured gap itself: ringCount must be sides+1 (5), NOT sides
    // (4) -- the historical "total copies including original" reading.
    assert(kp.count == 5,
        "toKernelParams: expected ringCount 5 (sides+1, open sweep), got " ~ kp.count.to!string);

    size_t inserted = m.revolveProfileEx([v1, v2], false, kp);
    assert(inserted == 4,
        "revolveProfileEx: expected 4 faces added, got " ~ inserted.to!string);

    size_t newVerts = m.vertices.length - vertsBefore;
    size_t newFaces = m.faces.length - facesBefore;
    assert(newVerts == 8,
        "MEASURED parity (toolcard discriminator_open4_nocap): expected +8 verts, got +"
        ~ newVerts.to!string);
    assert(newFaces == 4,
        "MEASURED parity (toolcard discriminator_open4_nocap): expected +4 faces, got +"
        ~ newFaces.to!string);

    // Frozen coordinates: ring k (k=1..4) is the profile rotated by
    // k*45deg (stepAngle = 180/(5-1) = 45deg) about the Y axis through the
    // origin -- derived independently from math.d's general Rodrigues
    // formula (pivotRotationMatrix) specialised to axis=(0,1,0):
    //   (x,y,z) -> (x*cosA + z*sinA, y, -x*sinA + z*cosA).
    // Regression-locks revolveProfileEx's rotation direction/order, not
    // just the topology counts above. Ring k's two new vertices were
    // appended in profile order (addVertex always appends, never dedups)
    // right after ring0's zero-new-vertex reuse.
    immutable float D2R = cast(float)(PI / 180.0);
    foreach (k; 1 .. 5) {
        float a = k * 45.0f * D2R;
        float c = cos(a), s = sin(a);
        Vec3 want1 = Vec3(p1.x * c + p1.z * s, p1.y, -p1.x * s + p1.z * c);
        Vec3 want2 = Vec3(p2.x * c + p2.z * s, p2.y, -p2.x * s + p2.z * c);

        Vec3 got1 = m.vertices[vertsBefore + (k - 1) * 2];
        Vec3 got2 = m.vertices[vertsBefore + (k - 1) * 2 + 1];

        assert(closeVec(got1, want1),
            "ring " ~ k.to!string ~ " vert1 mismatch: got " ~ got1.to!string ~ " want " ~ want1.to!string);
        assert(closeVec(got2, want2),
            "ring " ~ k.to!string ~ " vert2 mismatch: got " ~ got2.to!string ~ " want " ~ want2.to!string);
    }
}

// ---------------------------------------------------------------------------
// Cross-check: closed-360 sweep, reference Count=8 -- the case that CANNOT
// discriminate the Count convention (ring count == band count == Count
// either way). Toolcard measured +14v/+8f here too, which is what vibe3d's
// pre-existing revolveProfile(count=8, angle=2pi) already predicted from
// reading the kernel -- confirms toKernelParams leaves the closed-sweep
// path untranslated (kp.count == rp.sides, no +1).
// ---------------------------------------------------------------------------
unittest {
    Mesh m = makeCube();
    immutable uint v1 = 1, v2 = 2;

    size_t vertsBefore = m.vertices.length;
    size_t facesBefore = m.faces.length;

    RadialSweepParams rp;
    rp.sides         = 8;
    rp.axisPreset    = 1;
    rp.axis          = Vec3(0, 1, 0);
    rp.center        = Vec3(0, 0, 0);
    rp.startAngleDeg = 0.0f;
    rp.endAngleDeg   = 360.0f;
    rp.cap0          = false;
    rp.cap1          = false;

    auto kp = toKernelParams(rp);
    assert(kp.count == 8,
        "toKernelParams: closed 360 sweep must NOT add +1, expected ringCount 8, got "
        ~ kp.count.to!string);

    size_t inserted = m.revolveProfileEx([v1, v2], false, kp);
    assert(inserted == 8,
        "revolveProfileEx: expected 8 faces added, got " ~ inserted.to!string);
    assert(m.vertices.length - vertsBefore == 14,
        "MEASURED parity (toolcard closed360_count8): expected +14 verts, got +"
        ~ (m.vertices.length - vertsBefore).to!string);
    assert(m.faces.length - facesBefore == 8,
        "MEASURED parity (toolcard closed360_count8): expected +8 faces, got +"
        ~ (m.faces.length - facesBefore).to!string);
}

// ---------------------------------------------------------------------------
// RadialSweepTool's own preview-rebuild path (rebuildRadialSweepPreview),
// non-cumulative proof -- mirrors MirrorTool's module unittest
// (tools/mirror.d): N successive preview rebuilds against the SAME
// baseSnap/profile/params must all land on the same vertex/face count, not
// grow by 8 verts / 4 faces each time.
// ---------------------------------------------------------------------------
unittest {
    import snapshot : MeshSnapshot;

    Mesh cube = makeCube();
    MeshSnapshot baseSnap = MeshSnapshot.capture(cube);

    RadialSweepParams rp;
    rp.sides         = 4;
    rp.axisPreset    = 1;
    rp.axis          = Vec3(0, 1, 0);
    rp.center        = Vec3(0, 0, 0);
    rp.startAngleDeg = 0.0f;
    rp.endAngleDeg   = 180.0f;
    rp.cap0          = false;
    rp.cap1          = false;

    uint[] profile = [1u, 2u];
    Mesh previewMesh;
    size_t expectedVerts = size_t.max, expectedFaces = size_t.max;
    foreach (i; 0 .. 5) {
        rebuildRadialSweepPreview(baseSnap, previewMesh, profile, /*profileClosed*/false,
                                  uint.max, rp);
        if (i == 0) {
            expectedVerts = previewMesh.vertices.length;
            expectedFaces = previewMesh.faces.length;
            assert(expectedVerts == 16,
                "expected 8 (cube) + 8 (sweep) = 16 verts after one preview rebuild, got "
                ~ expectedVerts.to!string);
            assert(expectedFaces == 10,
                "expected 6 (cube) + 4 (sweep) = 10 faces after one preview rebuild, got "
                ~ expectedFaces.to!string);
        } else {
            assert(previewMesh.vertices.length == expectedVerts,
                "preview accumulated verts on repeat #" ~ i.to!string ~ ": expected "
                ~ expectedVerts.to!string ~ ", got " ~ previewMesh.vertices.length.to!string);
            assert(previewMesh.faces.length == expectedFaces,
                "preview accumulated faces on repeat #" ~ i.to!string ~ ": expected "
                ~ expectedFaces.to!string ~ ", got " ~ previewMesh.faces.length.to!string);
        }
    }
}

// ---------------------------------------------------------------------------
// B1 regression (task 0326 review — DoS): `toKernelParams` must clamp
// `sides` into [1, MAX_SWEEP_SIDES] BEFORE it ever reaches
// Mesh.RevolveParams.count. Pure-D, no HTTP -- defense-in-depth check for
// any caller reaching `toKernelParams` outside the Param-write path (which
// has its own PRIMARY clamp, exercised end-to-end by the HTTP-based test
// below).
// ---------------------------------------------------------------------------
unittest {
    RadialSweepParams huge;
    huge.sides        = 100_000_000;
    huge.endAngleDeg  = 180.0f;   // open sweep -> ringCount = sidesClamped+1
    auto kpHuge = toKernelParams(huge);
    assert(kpHuge.count == MAX_SWEEP_SIDES + 1,
        "toKernelParams: huge sides must clamp to MAX_SWEEP_SIDES+1 (open sweep), got "
        ~ kpHuge.count.to!string);

    RadialSweepParams negative;
    negative.sides = -5;   // default endAngleDeg=360 -> closed sweep -> no +1
    auto kpNeg = toKernelParams(negative);
    assert(kpNeg.count == 1,
        "toKernelParams: negative/zero sides must clamp to 1 (closed sweep), got "
        ~ kpNeg.count.to!string);
}

// ---------------------------------------------------------------------------
// B1 regression, end-to-end over HTTP: the ACTUAL vulnerable path was the
// headless `tool.attr <tool> sides <huge>` write, which (before this fix)
// wrote the unclamped value straight into `params_.sides`, and
// `ToolAttrCommand.apply()` unconditionally calls `onParamChanged` +
// `evaluate()` right after ANY attr write (regardless of session/interactive
// state) -- so `rebuildRadialSweepPreview` -> `revolveProfileEx` ran
// SYNCHRONOUSLY on the HTTP thread with an unbounded ring count (~1.6GB
// alloc at 1e8, hanging the editor). This test's own completion within the
// normal test timeout, plus the STORED value read back via the `?` query
// actually being clamped (not just the kernel's translated count), is the
// "clamped, not hung" proof.
// ---------------------------------------------------------------------------
unittest {
    import std.json    : JSONValue, parseJSON;
    import std.net.curl : get, post;

    enum string BASE = "http://localhost:8080";
    enum string TOOL = "mesh.radialSweepTool";

    JSONValue postJson(string path, string body_) {
        return parseJSON(cast(string) post(BASE ~ path, body_));
    }
    JSONValue getJson(string path) {
        return parseJSON(cast(string) get(BASE ~ path));
    }
    void httpCmd(string line) {
        auto r = postJson("/api/command", line);
        assert(r["status"].str == "ok" || r["status"].str == "success",
            "/api/command '" ~ line ~ "' failed: " ~ r.toString);
    }
    long qi(string attr) {
        auto r = postJson("/api/command", "tool.attr " ~ TOOL ~ " " ~ attr ~ " ?");
        assert(r["status"].str == "ok", "query " ~ attr ~ " failed: " ~ r.toString);
        return r["value"].integer;
    }

    // Reset cube, select the same interior edge {1,2} used by the primary
    // golden case above (edge index 2 on the default cube: vert1=
    // (0.5,-0.5,-0.5), vert2=(0.5,0.5,-0.5)).
    postJson("/api/reset", "");
    postJson("/api/select", `{"mode":"edges","indices":[2]}`);

    httpCmd("tool.set " ~ TOOL);
    httpCmd("tool.attr " ~ TOOL ~ " sides 100000000");

    long stored = qi("sides");
    assert(stored == MAX_SWEEP_SIDES,
        "tool.attr sides 100000000: expected the STORED value clamped to "
        ~ MAX_SWEEP_SIDES.to!string ~ ", got " ~ stored.to!string);

    httpCmd("tool.set " ~ TOOL ~ " off");

    // Default Start/End Angle (0/360) -> closed sweep -> ringCount ==
    // sidesClamped exactly (no +1): bounded, sane topology -- not the
    // multi-gigabyte allocation the unclamped huge value would have
    // attempted.
    auto m = getJson("/api/model");
    long wantFaces = 6 + MAX_SWEEP_SIDES;   // 6 base cube faces + one band/ring
    assert(m["faceCount"].integer == wantFaces,
        "clamped huge Count: expected " ~ wantFaces.to!string
        ~ " faces (6 base + " ~ MAX_SWEEP_SIDES.to!string ~ " sweep bands), got "
        ~ m["faceCount"].integer.to!string);
}
