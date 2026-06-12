// test_falloff_multi.d — HTTP-driven multi-falloff INSTANCE lifecycle
// (Phase 4 add/remove/clear of doc/falloff_multi_subtool_plan.md).
//
// What this pins:
//   • `falloff.add <type>` stacks a NEW FalloffStage instance in the WGHT
//     slot with a fresh unique id ("falloff#1", "falloff#2", …). DUPLICATES
//     of one type are allowed (two radials coexist).
//   • a secondary instance is addressable + editable by its id via
//     `tool.pipe.attr falloff#1 <attr>`.
//   • the second falloff actually PARTICIPATES in the combined weight: a
//     transform drag with two falloffs active produces a different
//     displacement than with one (the combiner already proves the math
//     unit-side in test_falloff_combine.d; here we prove the stacked
//     instance reaches the live transform path).
//   • `falloff.remove falloff#1` drops one; removing the PRIMARY "falloff"
//     is rejected; `falloff.clear` removes every extra, keeping the primary.
//   • a scene reset clears all extras → exactly one WGHT stage remains
//     (the byte-stable pre-stacking baseline).
//
// The /api/toolpipe `stages` array carries both `task` and `id` per stage,
// so WGHT-task stages are counted/addressed by id.

import std.net.curl;
import std.json;
import std.math : fabs, sqrt;
import std.conv : to;

import drag_helpers;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string) get(baseUrl ~ path));
}

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(baseUrl ~ path, body_));
}

// Raw post that tolerates an error status (for the reject-path assertions).
string postRaw(string path, string body_) {
    return cast(string) post(baseUrl ~ path, body_);
}

void cmd(string c) {
    auto r = postJson("/api/command", c);
    assert(r["status"].str == "ok", "command failed: " ~ c ~ " -> " ~ r.toString);
}

// All WGHT-task stage ids, in pipeline order.
string[] wghtStageIds() {
    auto j = getJson("/api/toolpipe");
    string[] ids;
    foreach (st; j["stages"].array)
        if (st["task"].str == "WGHT")
            ids ~= st["id"].str;
    return ids;
}

// Attrs of a specific WGHT stage by id.
string[string] wghtAttrsById(string id) {
    auto j = getJson("/api/toolpipe");
    foreach (st; j["stages"].array) {
        if (st["task"].str == "WGHT" && st["id"].str == id) {
            string[string] out_;
            foreach (k, v; st["attrs"].object) out_[k] = v.str;
            return out_;
        }
    }
    assert(false, "WGHT stage '" ~ id ~ "' missing from /api/toolpipe");
}

void resetCube() {
    postJson("/api/reset", `{"primitive":"cube"}`);
}

// -------------------------------------------------------------------------
// Reset leaves exactly ONE WGHT stage (the primary). Establishes the
// baseline the other tests build on.
// -------------------------------------------------------------------------
unittest {
    resetCube();
    auto ids = wghtStageIds();
    assert(ids.length == 1,
        "fresh reset should leave exactly one WGHT stage; got " ~ ids.to!string);
    assert(ids[0] == "falloff",
        "the sole WGHT stage is the primary 'falloff'; got " ~ ids[0]);
}

// -------------------------------------------------------------------------
// falloff.add radial TWICE → THREE WGHT stages total (primary + two
// extras), and the two extras are TWO OF THE SAME TYPE (both radial).
// -------------------------------------------------------------------------
unittest {
    resetCube();
    cmd("falloff.add radial");
    cmd("falloff.add radial");

    auto ids = wghtStageIds();
    assert(ids.length == 3,
        "two adds → primary + 2 extras = 3 WGHT stages; got " ~ ids.to!string);
    assert(ids[0] == "falloff",  "primary first; got " ~ ids.to!string);
    assert(ids[1] == "falloff#1", "first extra id; got " ~ ids.to!string);
    assert(ids[2] == "falloff#2", "second extra id; got " ~ ids.to!string);

    // Both extras are the SAME type (radial) and coexist independently.
    assert(wghtAttrsById("falloff#1")["type"] == "radial",
        "falloff#1 type should be radial");
    assert(wghtAttrsById("falloff#2")["type"] == "radial",
        "falloff#2 type should be radial");

    // Leave a clean slate for the next test in this worker.
    cmd("falloff.clear");
}

// -------------------------------------------------------------------------
// A secondary instance is addressable + editable via `tool.pipe.attr
// falloff#1 <attr>` and reads back through /api/toolpipe.
// -------------------------------------------------------------------------
unittest {
    resetCube();
    cmd("falloff.add radial");
    cmd(`tool.pipe.attr falloff#1 center "1,0,0"`);
    cmd("tool.pipe.attr falloff#1 size \"2,2,2\"");

    auto a = wghtAttrsById("falloff#1");
    assert(a["center"] == "1,0,0", "falloff#1 center: " ~ a["center"]);
    assert(a["size"]   == "2,2,2", "falloff#1 size: "   ~ a["size"]);

    // The primary is untouched by an edit addressed at the extra.
    auto p = wghtAttrsById("falloff");
    assert(p["center"] == "0,0,0",
        "primary center must be unchanged by a falloff#1 edit; got " ~ p["center"]);

    cmd("falloff.clear");
}

// -------------------------------------------------------------------------
// The second falloff PARTICIPATES in the combined weight reaching the live
// transform: a Y-drag with TWO falloffs attenuating produces a strictly
// smaller displacement at a corner than with just one falloff.
// -------------------------------------------------------------------------
unittest {
    bool approx(double a, double b, double eps = 1e-3) { return fabs(a - b) < eps; }

    double dragOnceMeasureDy0() {
        // Select the whole cube; configure the PRIMARY radial so v0
        // (-0.5,-0.5,-0.5) is at full weight and the gizmo pivot is origin.
        auto selResp = post(baseUrl ~ "/api/select",
                            `{"mode":"vertices","indices":[0,1,2,3,4,5,6,7]}`);
        assert(parseJSON(cast(string)selResp)["status"].str == "ok",
            "select failed: " ~ cast(string)selResp);

        double[3] pre0 = vertexPos(0);

        auto cam = fetchCamera();
        auto vp  = viewportFromCamera(cam);
        Vec3 pivot = Vec3(0, 0, 0);
        float size = gizmoSize(pivot, vp);
        Vec3 arrowStart = Vec3(pivot.x, pivot.y + size / 6.0f, pivot.z);
        Vec3 arrowEnd   = Vec3(pivot.x, pivot.y + size,         pivot.z);
        float sx1, sy1, sx2, sy2;
        assert(projectToWindow(arrowStart, vp, sx1, sy1), "Y-arrow start off-camera");
        assert(projectToWindow(arrowEnd,   vp, sx2, sy2), "Y-arrow end off-camera");
        int x0 = cast(int)(sx1 + 0.7f * (sx2 - sx1));
        int y0 = cast(int)(sy1 + 0.7f * (sy2 - sy1));
        double sdx = cast(double)(sx2 - sx1), sdy = cast(double)(sy2 - sy1);
        double sLen = sqrt(sdx*sdx + sdy*sdy);
        int x1 = x0 + cast(int)(100.0 * sdx / sLen);
        int y1 = y0 + cast(int)(100.0 * sdy / sLen);

        string log = buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                                  x0, y0, x1, y1, 20);
        playAndWait(log);
        return vertexPos(0)[1] - pre0[1];
    }

    // --- single falloff: primary radial centred at v0, large sphere. ---
    resetCube();
    cmd("tool.set move");
    cmd("tool.pipe.attr falloff type radial");
    cmd(`tool.pipe.attr falloff center "-0.5,-0.5,-0.5"`);
    cmd(`tool.pipe.attr falloff size "2,2,2"`);
    double dySingle = dragOnceMeasureDy0();
    assert(dySingle > 0.05,
        "v0 should move under a single full-weight radial; dy=" ~ dySingle.to!string);

    // --- two falloffs: add a SECOND radial that attenuates v0 (centre far
    // away so v0 gets a sub-1 weight); multiply-combined it must shrink v0's
    // motion vs the single-falloff case. ---
    resetCube();
    cmd("tool.set move");
    cmd("tool.pipe.attr falloff type radial");
    cmd(`tool.pipe.attr falloff center "-0.5,-0.5,-0.5"`);
    cmd(`tool.pipe.attr falloff size "2,2,2"`);
    cmd("falloff.add radial");
    // Centre the extra at the OPPOSITE corner so v0 lands mid-falloff → weight < 1.
    cmd(`tool.pipe.attr falloff#1 center "0.5,0.5,0.5"`);
    cmd(`tool.pipe.attr falloff#1 size "2,2,2"`);
    cmd("tool.pipe.attr falloff#1 mix multiply");
    double dyDouble = dragOnceMeasureDy0();

    assert(dyDouble >= 0,
        "v0 displacement must stay non-negative; got " ~ dyDouble.to!string);
    assert(dyDouble < dySingle - 1e-3,
        "the stacked second falloff must attenuate v0's motion: " ~
        "single=" ~ dySingle.to!string ~ " double=" ~ dyDouble.to!string);

    cmd("falloff.clear");
}

// -------------------------------------------------------------------------
// remove one extra by id → back to one extra; remove the PRIMARY → rejected;
// clear → only the primary remains.
// -------------------------------------------------------------------------
unittest {
    resetCube();
    cmd("falloff.add radial");
    cmd("falloff.add linear");
    assert(wghtStageIds().length == 3, "two adds → 3 stages");

    // Remove the first extra by id.
    cmd("falloff.remove falloff#1");
    auto afterRemove = wghtStageIds();
    assert(afterRemove.length == 2,
        "after removing one extra, 2 WGHT stages remain; got " ~ afterRemove.to!string);
    // The surviving extra keeps its id (falloff#2 is not renumbered).
    assert(afterRemove[0] == "falloff",
        "primary survives; got " ~ afterRemove.to!string);
    assert(afterRemove[1] == "falloff#2",
        "the un-removed extra keeps its id; got " ~ afterRemove.to!string);

    // Removing the primary is rejected — error status, primary stays.
    auto raw = postRaw("/api/command", "falloff.remove falloff");
    auto rj  = parseJSON(raw);
    assert(rj["status"].str != "ok",
        "removing the primary 'falloff' must be rejected; got " ~ raw);
    assert(wghtStageIds().length == 2,
        "rejected primary-remove must not change the stage set");

    // Clear removes every extra, keeping the primary.
    cmd("falloff.clear");
    auto afterClear = wghtStageIds();
    assert(afterClear.length == 1 && afterClear[0] == "falloff",
        "clear leaves only the primary; got " ~ afterClear.to!string);
}

// -------------------------------------------------------------------------
// A scene reset with extras active clears them — exactly one WGHT stage
// remains (the byte-stable pre-stacking baseline).
// -------------------------------------------------------------------------
unittest {
    resetCube();
    cmd("falloff.add radial");
    cmd("falloff.add radial");
    assert(wghtStageIds().length == 3, "two adds → 3 stages before reset");

    resetCube();
    auto ids = wghtStageIds();
    assert(ids.length == 1,
        "a reset must clear stacked extras → one WGHT stage; got " ~ ids.to!string);
    assert(ids[0] == "falloff",
        "the surviving stage is the primary; got " ~ ids[0]);
}

// -------------------------------------------------------------------------
// id reuse: removing falloff#1 frees the slot — the next add reuses it.
// -------------------------------------------------------------------------
unittest {
    resetCube();
    cmd("falloff.add radial");       // falloff#1
    cmd("falloff.add radial");       // falloff#2
    cmd("falloff.remove falloff#1"); // frees #1
    cmd("falloff.add radial");       // should reclaim falloff#1

    auto ids = wghtStageIds();
    assert(ids.length == 3, "two surviving extras + primary; got " ~ ids.to!string);
    bool has1, has2;
    foreach (id; ids) {
        if (id == "falloff#1") has1 = true;
        if (id == "falloff#2") has2 = true;
    }
    assert(has1 && has2,
        "the freed falloff#1 slot is reused on the next add; got " ~ ids.to!string);

    cmd("falloff.clear");
}
