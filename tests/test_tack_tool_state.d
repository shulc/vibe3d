// Tack (mesh.tack) hover-state semantics via /api/tool/state — task 0126,
// mirroring tests/test_loop_slice_hover_state.d's pattern (drive a real
// cursor hover via SDL_MOUSEMOTION play-events, assert on the resulting
// transient state — no click, no hardcoded pixels beyond what the fixture
// geometry + camera framing guarantee). See tests/test_tack_tool.d for the
// commit/undo/parity coverage this file does NOT duplicate.

import std.net.curl;
import std.json;
import std.conv : to;
import std.string : format;
import core.thread : Thread;
import core.time : msecs;

import drag_helpers;

void main() {}

enum string baseUrl = "http://localhost:8080";
enum int    SRC_FACE = 4;
enum int    TGT_FACE = 10;

string sceneJson() {
    return `{
      "vertices": [
        [-2.5, -0.5, -0.5], [-2.5, -0.5, 0.5], [-2.5, 0.5, -0.2], [-2.5, 0.5, 0.5],
        [-1.5, -0.5, -0.5], [-1.5, -0.5, 0.5], [-1.5, 0.5, -0.5], [-1.5, 0.5, 0.5],
        [2.5, -0.5, -0.5], [2.5, -0.5, 0.5], [2.5, 0.5, -0.5], [2.5, 1.3, 0.5],
        [3.5, -0.5, -0.5], [3.5, -0.5, 0.5], [3.5, 0.5, -0.5], [3.5, 1.3, 0.5]
      ],
      "faces": [
        [0,2,6,4],[1,5,7,3],[0,1,3,2],[4,6,7,5],[2,3,7,6],[0,4,5,1],
        [8,10,14,12],[9,13,15,11],[8,9,11,10],[12,14,15,13],[10,11,15,14],[8,12,13,9]
      ]
    }`;
}

void loadScene() {
    auto r = parseJSON(cast(string) post(baseUrl ~ "/api/load-mesh", sceneJson()));
    assert(r["status"].str == "ok", "load-mesh failed: " ~ r.toString);
}

void selectFaces(int[] idx) {
    string idxJson = "[";
    foreach (k, v; idx) { if (k) idxJson ~= ","; idxJson ~= v.to!string; }
    idxJson ~= "]";
    auto r = parseJSON(cast(string) post(baseUrl ~ "/api/select",
        format(`{"mode":"polygons","indices":%s}`, idxJson)));
    assert(r["status"].str == "ok", "select failed: " ~ r.toString);
}

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(baseUrl ~ path, body_));
}

void cmd(string body_) {
    auto r = postJson("/api/command", body_);
    assert(r["status"].str == "ok", "/api/command '" ~ body_ ~ "' failed: " ~ r.toString);
}

void toolSet(string id) { cmd("tool.set " ~ id); }
void toolOff(string id) { cmd("tool.set " ~ id ~ " off"); }

JSONValue getToolState() { return parseJSON(cast(string) get(baseUrl ~ "/api/tool/state")); }

void settle() { Thread.sleep(150.msecs); }

void frameTargetFace() {
    // Same framing as test_tack_tool.d: eye above (+Y) and in front (-Z) of
    // Box B's tilted +Y face (centroid (3,0.9,0)); Box A is far outside the
    // frustum.
    postJson("/api/camera",
        `{"azimuth":3.14159265,"elevation":0.9,"distance":6,` ~
        `"focus":{"x":3.0,"y":0.9,"z":0.0}}`);
}

string hoverLog(int vpX, int vpY, int vpW, int vpH, int x, int y) {
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        vpX, vpY, vpW, vpH);
    foreach (i; 0 .. 5)
        log ~= format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n",
            50.0 + i * 20.0, x, y);
    return log;
}

// ---------------------------------------------------------------------------
// 1. Hover a valid target polygon with a source polygon selected: state
//    reports the pre-selected sourceFace, the hovered target, and an active
//    preview.
// ---------------------------------------------------------------------------
unittest {
    loadScene();
    selectFaces([SRC_FACE]);
    frameTargetFace();
    toolSet("mesh.tack");

    auto cam = fetchCamera(baseUrl);
    auto vp  = viewportFromCamera(cam);
    // Target centroid (3, 0.9, 0) — well inside the framed face, no need for
    // the exact clicked anchor point (this test only cares about the hovered
    // FACE index, not the anchor).
    Vec3 tgtCentroid = Vec3(3.0f, 0.9f, 0.0f);
    float sx, sy;
    assert(projectToWindow(tgtCentroid, vp, sx, sy),
        "target centroid should project on-camera with this framing");

    playAndWait(hoverLog(cam.vpX, cam.vpY, cam.width, cam.height,
                        cast(int) sx, cast(int) sy));
    settle();

    auto st = getToolState();
    assert(st["tool"].str == "mesh.tack", "expected mesh.tack tool state, got: " ~ st.toString);
    assert(st["sourceFace"].integer == SRC_FACE,
        "sourceFace mismatch: " ~ st.toString);
    assert(st["hoveredTargetFace"].integer == TGT_FACE,
        "hoveredTargetFace mismatch: " ~ st.toString);
    assert(st["previewActive"].type == JSONType.true_,
        "previewActive should be true while hovering a valid target with a source selected: "
        ~ st.toString);

    toolOff("mesh.tack");
}

// ---------------------------------------------------------------------------
// 2. Hover empty space (no geometry under the cursor): hoveredTargetFace is
//    -1 and no preview is shown, even with a valid source selected.
// ---------------------------------------------------------------------------
unittest {
    loadScene();
    selectFaces([SRC_FACE]);
    frameTargetFace();
    toolSet("mesh.tack");

    auto cam = fetchCamera(baseUrl);
    // Top-left corner of the viewport: with this tight framing on Box B
    // alone (Box A is outside the frustum), the corner is background.
    playAndWait(hoverLog(cam.vpX, cam.vpY, cam.width, cam.height,
                        cam.vpX + 5, cam.vpY + 5));
    settle();

    auto st = getToolState();
    assert(st["hoveredTargetFace"].integer == -1,
        "expected no hovered face over background, got: " ~ st.toString);
    assert(st["previewActive"].type == JSONType.false_,
        "previewActive should be false with nothing hovered: " ~ st.toString);

    toolOff("mesh.tack");
}

// ---------------------------------------------------------------------------
// 3. No source polygon selected: hovering a valid target still reports the
//    hover (hoveredTargetFace tracks the cursor unconditionally), but
//    sourceFace is -1 and previewActive is false — the no-op guard is
//    visible at the state level, not just in the final geometry.
// ---------------------------------------------------------------------------
unittest {
    loadScene();
    selectFaces([]);   // no pre-selection
    frameTargetFace();
    toolSet("mesh.tack");

    auto cam = fetchCamera(baseUrl);
    auto vp  = viewportFromCamera(cam);
    Vec3 tgtCentroid = Vec3(3.0f, 0.9f, 0.0f);
    float sx, sy;
    assert(projectToWindow(tgtCentroid, vp, sx, sy),
        "target centroid should project on-camera with this framing");

    playAndWait(hoverLog(cam.vpX, cam.vpY, cam.width, cam.height,
                        cast(int) sx, cast(int) sy));
    settle();

    auto st = getToolState();
    assert(st["sourceFace"].integer == -1,
        "expected no source face selected: " ~ st.toString);
    assert(st["previewActive"].type == JSONType.false_,
        "previewActive should be false with no source polygon selected: "
        ~ st.toString);

    toolOff("mesh.tack");
}
