// Reference-parity: Smooth Shift + Thicken (mesh.smoothShiftTool, task 0358).
// A topology-CHANGING interactive tool (adds cap/skin verts+faces), so it is
// verified with the topology-diff suite (count deltas + bidirectional
// position match), not the rigid-cluster before/after-pair verifier. No
// reference engine runs at test time — the golden geometry in
// fixtures/smooth_shift.json was transcribed once from a frozen reference
// capture and cross-checked analytically (see the smoothShiftFacesByMask
// doc comment in source/mesh.d for the derived law).

import fixture_helpers;
import std.json : JSONValue;

void main() {}

unittest {
    enum string json = import("fixtures/smooth_shift.json");
    runTopologyDiffSuite(json);
}

// Newell-method face normal (matches the convention in tests/test_thicken.d's
// faceNorm helper). Not private — reused by both unittest blocks below.
double[3] faceNewellNormal(JSONValue model, JSONValue faceArr) {
    import std.math : sqrt;
    auto idx   = faceArr.array;
    auto verts = model["vertices"].array;
    double nx = 0, ny = 0, nz = 0;
    foreach (k; 0 .. idx.length) {
        auto a = verts[cast(size_t)idx[k].integer].array;
        auto b = verts[cast(size_t)idx[(k + 1) % idx.length].integer].array;
        double ax = asDouble(a[0]), ay = asDouble(a[1]), az = asDouble(a[2]);
        double bx = asDouble(b[0]), by = asDouble(b[1]), bz = asDouble(b[2]);
        nx += (ay - by) * (az + bz);
        ny += (az - bz) * (ax + bx);
        nz += (ax - bx) * (ay + by);
    }
    double len = sqrt(nx*nx + ny*ny + nz*nz);
    if (len < 1e-9) return [0.0, 0.0, 0.0];
    return [nx/len, ny/len, nz/len];
}

unittest { // ThickenPresetActuallyThickens
    // Regression pin (review fix, task 0358): the mesh.thickenTool PRESET
    // path — base tool + thicken=true forced at FACTORY time via
    // config/tool_presets.yaml's `attrs:` block — must actually build the
    // thicken topology. A prior bug in SmoothShiftTool.reinitSession()
    // unconditionally reset thicken_ (and shift_/scale_/maxAngle_/sharp_)
    // back to their hardcoded defaults on activate(), which ran AFTER the
    // preset's applyToolAttrs() had already forced thicken_=true — silently
    // making the Thicken button behave identically to plain Smooth Shift
    // (proven live: preset path built 10 faces instead of 11). This must be
    // exercised via the PRESET id itself (`mesh.thickenTool`), NOT base tool
    // + `tool.attr … thicken 1` (that path is already covered by the
    // topology-diff suite above and never touched the clobbered field).
    import std.net.curl : get;
    import std.json     : parseJSON;
    import std.conv     : to;

    enum string BASE = "http://localhost:8080";
    runStep(parseJSON(`{"reset": true}`), "thickenTool_preset", "setup", 0);
    runStep(parseJSON(`{"select": {"mode": "polygons", "coords": [
        [[-0.5,0.5,-0.5],[0.5,0.5,-0.5],[0.5,0.5,0.5],[-0.5,0.5,0.5]]
    ]}}`), "thickenTool_preset", "setup", 1);

    // Deliberately no explicit `thicken` tool.attr here — the preset alone
    // must supply it.
    cmd("tool.set mesh.thickenTool on", "thickenTool_preset");
    cmd("tool.doApply", "thickenTool_preset");
    cmd("tool.set mesh.thickenTool off", "thickenTool_preset");

    auto model = parseJSON(cast(string) get(BASE ~ "/api/model"));
    long faces = model["faceCount"].integer;
    assert(faces == 11,
        "mesh.thickenTool preset: expected 11 faces (thicken retained-face " ~
        "branch), got " ~ faces.to!string ~ " -- if this is 10, " ~
        "reinitSession() is clobbering the preset's forced thicken=true again");
}

unittest { // ThickenWindingReversed
    // SHOULD-FIX (review, task 0358): thicken's retained face must be
    // winding-REVERSED relative to the cap it sits opposite — face-count
    // alone (11 vs 10) cannot distinguish a same-winding retained face from
    // a correctly reversed one. Uses shift=0.3 (base tool path, matching the
    // frozen "thicken_top_only" combo) so the cap (y=0.8) and the retained
    // face (y=0.5, unmoved original) are unambiguous by position.
    import std.net.curl : get;
    import std.json     : parseJSON;
    import std.math     : abs;
    import std.format   : format;

    enum string BASE = "http://localhost:8080";
    runStep(parseJSON(`{"reset": true}`), "thicken_winding", "setup", 0);
    runStep(parseJSON(`{"select": {"mode": "polygons", "coords": [
        [[-0.5,0.5,-0.5],[0.5,0.5,-0.5],[0.5,0.5,0.5],[-0.5,0.5,0.5]]
    ]}}`), "thicken_winding", "setup", 1);
    cmd("tool.set mesh.smoothShiftTool on", "thicken_winding");
    cmd("tool.attr mesh.smoothShiftTool shift 0.3", "thicken_winding");
    cmd("tool.attr mesh.smoothShiftTool thicken 1", "thicken_winding");
    cmd("tool.doApply", "thicken_winding");
    cmd("tool.set mesh.smoothShiftTool off", "thicken_winding");

    auto model = parseJSON(cast(string) get(BASE ~ "/api/model"));
    assert(model["faceCount"].integer == 11, "thicken winding test: expected 11 faces");

    auto verts = model["vertices"].array;
    ptrdiff_t capFi = -1, retainedFi = -1;
    foreach (fi, f; model["faces"].array) {
        auto fv = f.array;
        if (fv.length != 4) continue;
        bool allCap = true, allRetained = true;
        foreach (vi; fv) {
            double y = asDouble(verts[cast(size_t)vi.integer].array[1]);
            if (abs(y - 0.8) > 1e-3) allCap = false;
            if (abs(y - 0.5) > 1e-3) allRetained = false;
        }
        if (allCap)      capFi      = cast(ptrdiff_t)fi;
        if (allRetained) retainedFi = cast(ptrdiff_t)fi;
    }
    assert(capFi >= 0,      "thicken winding test: no cap face found (y~0.8)");
    assert(retainedFi >= 0, "thicken winding test: no retained face found (y~0.5)");
    assert(capFi != retainedFi, "thicken winding test: cap and retained face resolved to the same face");

    auto capN      = faceNewellNormal(model, model["faces"].array[capFi]);
    auto retainedN = faceNewellNormal(model, model["faces"].array[retainedFi]);
    double dotP = capN[0]*retainedN[0] + capN[1]*retainedN[1] + capN[2]*retainedN[2];
    assert(dotP < -0.9,
        format("thicken winding test: cap normal %s and retained-face normal " ~
               "%s should OPPOSE (dot < -0.9), got dot=%.4f -- retained face " ~
               "is not winding-reversed", capN, retainedN, dotP));
}
