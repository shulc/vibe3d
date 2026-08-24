// UNDER A DISPLAY STYLE THAT DRAWS NO FACES, A VERTEX OR EDGE BEHIND THE
// SURFACE IS PICKABLE (task 1830).
//
// The picker's occlusion for vertices and edges is ONE thing: a face depth
// pre-pass rendered into the ID buffer before the element pass, so anything
// behind a face fails the depth test and keeps id 0. Under the wireframe style
// no faces are drawn, so that pre-pass models a surface that is not on screen.
// `select_visibility.d` resolves the policy from the cell's own draw plan and
// `gpu_select` skips the pre-pass when the occlusion term is off.
//
// ---------------------------------------------------------------------------
// WHY THE RIG IS THREE OPEN QUADS AND NOT A CUBE
// ---------------------------------------------------------------------------
// On a closed solid "back-facing" and "occluded" are the same set, so every
// candidate rule agrees and the test is green on the broken code too —
// CLAUDE.md records the trap, and it has already cost this project two runs
// (deleting the facing term outright once left all five snap tests green).
// The rig separates the two axes on purpose:
//
//   near   (±2,   ±2,   +1)  CCW  the occluder
//   far    (±0.6, ±0.6, −1)  CCW  OCCLUDED and FRONT-facing
//   side   (3..4.5, ±1,  0)  CW   BACK-facing and UNOCCLUDED
//
// Camera on +Z at distance 12: the far quad's corners land ~35 px from the
// centre, the near quad's ~137 px, the side quad ~180 px to the right. No
// element is ever within the vertex radius (4 px) or the edge radius (6 px) of
// a second candidate, so the picker's manhattan tie-break never runs and every
// answer below is unambiguous.
//
// ---------------------------------------------------------------------------
// THE CELLS, AND WHAT EACH ONE SEPARATES
// ---------------------------------------------------------------------------
//   A0  shaded    near corner  -> idxNear   POSITIVE CONTROL, and it runs
//                                            FIRST: `-1` is also what the app
//                                            publishes when the hover picker
//                                            never ran at all (`hovered = -1`
//                                            is written before three early
//                                            returns), so without a positive
//                                            control every `-1` below would be
//                                            satisfied by a broken harness.
//   A   shaded    far corner   -> -1        the pre-pass occludes
//   B   wireframe far corner   -> idxFar    THE CHANGE
//   C   shaded    far corner   -> -1        the invalidation goes both ways
//   D   both      side corner  -> idxSide   the click path has NO facing term
//                                            (a measured law) — this is the
//                                            guard on the resolved-but-
//                                            unconsumed `facingTerm`
//   E   both      far edge     -> -1 / idx  edges follow vertices (with its
//                                            own positive control on a near
//                                            edge)
//   F   both      /api/pick    -> same idx  CHARACTERISATION PIN, NOT A
//                                            DISCRIMINATOR: `renderMode` never
//                                            runs the pre-pass for the face
//                                            mode, so the term is inert there
//                                            BY CONSTRUCTION and this cell
//                                            cannot come out differently under
//                                            any mutation of this task. It
//                                            pins the declared scope — faces
//                                            do NOT pick through — and it is
//                                            MEANT to break when the face
//                                            follow-up lands an accumulating
//                                            BVH traversal.
//   G   both      lasso band   -> 4 / 0     the lasso's vertex half reads the
//                                            same ID buffer and moves with it
//
// B AND C ARE ALSO THE CACHE-KEY CELLS, AND THEIR CONSTRUCTION IS LOAD-BEARING.
// Between A, B and C this test does not reset, does not reload the mesh, does
// not move the camera and does not replay a single event — it flips
// `viewport.displayStyle` and reads the hover the app re-picks every frame at
// the parked pointer. That is exactly the state in which the picker's slot key
// (upload version, composed view, projection, FBO size) is unchanged in every
// term: without the policy term in that key the slot stays `valid` and B is
// answered out of A's FBO.

import std.net.curl;
import std.json;
import std.math   : fabs, lround;
import std.conv   : to;
import std.format : format;
import std.algorithm : canFind;
import core.thread : Thread;
import core.time   : msecs;

import drag_helpers;

void main() {}

enum string BASE = "http://localhost:8080";

JSONValue getJson(string p)              { return parseJSON(cast(string)get(BASE ~ p)); }
JSONValue postJson(string p, string b)   { return parseJSON(cast(string)post(BASE ~ p, b)); }

void settle() { Thread.sleep(300.msecs); }

void cmdOk(string body_) {
    auto resp = cast(string)post(BASE ~ "/api/command", body_);
    auto r = parseJSON(resp);
    assert("status" !in r || r["status"].str != "error",
           "command failed: " ~ body_ ~ " -> " ~ resp);
}

void setStyle(string s) {
    cmdOk(format(`{"id":"viewport.displayStyle","params":"%s"}`, s));
    settle();
}

void setMode(string m) {
    auto r = postJson("/api/select", format(`{"mode":"%s","indices":[]}`, m));
    assert(r["status"].str == "success" || r["status"].str == "ok",
           "/api/select " ~ m ~ " failed: " ~ r.toString);
    settle();
}

// The three-quad rig. Winding is stated per face; `side` is reversed so its
// normal points AWAY from an eye on +Z.
enum string RIG = `{"vertices":[
    [-2,-2,1],[2,-2,1],[2,2,1],[-2,2,1],
    [-0.6,-0.6,-1],[0.6,-0.6,-1],[0.6,0.6,-1],[-0.6,0.6,-1],
    [3,-1,0],[4.5,-1,0],[4.5,1,0],[3,1,0]],
 "faces":[[0,1,2,3],[4,5,6,7],[8,11,10,9]]}`;

// Vertex roles, by index into RIG.
enum int V_NEAR = 2;   // (2, 2, 1)      near quad corner
enum int V_FAR  = 6;   // (0.6, 0.6, -1) far quad corner, occluded by the near quad
enum int V_SIDE = 8;   // (3, -1, 0)     side quad corner, back-facing, unoccluded

Vec3 rigVert(int i) {
    auto v = getJson("/api/model")["vertices"].array[i].array;
    return Vec3(cast(float)v[0].floating, cast(float)v[1].floating,
                cast(float)v[2].floating);
}

// Hover-only play-events batch — five motion events at one pixel, no buttons.
// The replayed pointer is NOT cleared when the batch ends (eventlog.d says so
// in as many words), so the app keeps re-picking hover at (x,y) every frame
// afterwards: that is what lets cells B and C flip only the display style.
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

// A closed rectangular RMB path — the lasso needs a polygon with area, which a
// straight `buildDragLog` drag does not have.
string lassoLog(int vpX, int vpY, int vpW, int vpH,
                int x0, int y0, int x1, int y1) {
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        vpX, vpY, vpW, vpH);
    double t = 50.0;
    log ~= format(
        `{"t":%.3f,"type":"SDL_MOUSEBUTTONDOWN","btn":3,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        t, x0, y0);
    int px = x0, py = y0;
    void go(int x, int y) {
        t += 25.0;
        log ~= format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":4,"mod":0}` ~ "\n",
            t, x, y, x - px, y - py);
        px = x; py = y;
    }
    // Four sides, four samples each — enough points that the path is a real
    // polygon rather than a triangle fan artefact.
    foreach (i; 1 .. 5) go(x0 + (x1 - x0) * i / 4, y0);
    foreach (i; 1 .. 5) go(x1, y0 + (y1 - y0) * i / 4);
    foreach (i; 1 .. 5) go(x1 - (x1 - x0) * i / 4, y1);
    foreach (i; 1 .. 5) go(x0, y1 - (y1 - y0) * i / 4);
    t += 25.0;
    log ~= format(
        `{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":3,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        t, x0, y0);
    return log;
}

// Load the rig, aim the camera down −Z from +Z, and hand back the camera the
// projections below are computed with.
CameraState setupRig() {
    postJson("/api/reset", "");
    settle();
    auto lm = postJson("/api/load-mesh", RIG);
    assert(lm["status"].str == "ok" || lm["status"].str == "success",
           "/api/load-mesh failed: " ~ lm.toString);
    // AFTER the load: /api/load-mesh re-frames the camera.
    postJson("/api/camera", `{"azimuth":0,"elevation":0,"distance":12}`);
    settle();

    auto model = getJson("/api/model");
    assert(model["vertices"].array.length == 12,
           format("rig did not load: %d vertices", model["vertices"].array.length));
    assert(model["faces"].array.length == 3,
           format("rig did not load: %d faces", model["faces"].array.length));

    auto cam = fetchCamera();
    // THE RECONSTRUCTION IS PART OF THE TEST, not a nicety: every role above
    // ("occluded", "back-facing") is a statement about where the eye is. If
    // the azimuth convention put it elsewhere the roles would swap silently
    // and the cells would still all be answerable.
    assert(cam.eye.z > 1.0f && fabs(cam.eye.x) < 0.1f && fabs(cam.eye.y) < 0.1f,
           format("camera is not on +Z looking at the origin: eye=(%s,%s,%s)",
                  cam.eye.x, cam.eye.y, cam.eye.z));
    // And the fixture itself: the roles are coordinates, so assert them.
    auto vn = rigVert(V_NEAR), vf = rigVert(V_FAR), vs = rigVert(V_SIDE);
    assert(fabs(vn.z - 1.0f) < 1e-4 && fabs(vf.z + 1.0f) < 1e-4,
           "fixture drifted: the near quad must be in front of the far one");
    assert(vs.x > 2.5f, "fixture drifted: the side quad must clear the near quad");
    return cam;
}

// World point -> window pixel, with the live camera.
void px(Vec3 w, ref CameraState cam, out int x, out int y) {
    auto vp = viewportFromCamera(cam);
    float sx, sy;
    assert(projectToWindow(w, vp, sx, sy),
           format("world point off-camera: (%s,%s,%s)", w.x, w.y, w.z));
    x = cast(int)lround(sx);
    y = cast(int)lround(sy);
}

void hoverAt(ref CameraState cam, int x, int y) {
    playAndWait(hoverLog(cam.vpX, cam.vpY, cam.width, cam.height, x, y));
    settle();
}

// The published hover state lives on `/api/toolpipe/eval` (`hover.vertex` /
// `hover.edge`, -1 = nothing), refreshed every frame from the same pickers the
// click path uses.
int hoverVertex() { return cast(int)getJson("/api/toolpipe/eval")["hover"]["vertex"].integer; }
int hoverEdge()   { return cast(int)getJson("/api/toolpipe/eval")["hover"]["edge"].integer; }

int[] edgeEnds(int ei) {
    auto e = getJson("/api/model")["edges"].array[ei].array;
    return [cast(int)e[0].integer, cast(int)e[1].integer];
}

// ---------------------------------------------------------------------------
// Cells A0..F — hover / click / paint (one code path) and the face oracle.
// ---------------------------------------------------------------------------
unittest {
    auto cam = setupRig();
    setMode("vertices");
    assert(getJson("/api/selection")["selType"].str == "vertex",
           "the vertex picker will not run unless the current selection type "
           ~ "is vertex — every `-1` below would then be vacuous");

    int nx, ny, fx, fy, sx_, sy_;
    px(rigVert(V_NEAR), cam, nx, ny);
    px(rigVert(V_FAR),  cam, fx, fy);
    px(rigVert(V_SIDE), cam, sx_, sy_);
    // The three probes must be far apart, or one pick could answer for another.
    assert((nx - fx) * (nx - fx) + (ny - fy) * (ny - fy) > 60 * 60,
           format("near (%d,%d) and far (%d,%d) project too close together",
                  nx, ny, fx, fy));

    setStyle("shaded");

    // ---- A0: POSITIVE CONTROL, first --------------------------------------
    hoverAt(cam, nx, ny);
    assert(hoverVertex() == V_NEAR,
           format("A0 positive control: hovering the near quad's corner at "
                  ~ "(%d,%d) must pick vertex %d, got %d — the harness is not "
                  ~ "picking at all, so no `-1` below means 'occluded'",
                  nx, ny, V_NEAR, hoverVertex()));

    // ---- A: the far vertex is occluded in a shaded cell --------------------
    hoverAt(cam, fx, fy);
    assert(hoverVertex() == -1,
           format("A: in a shaded cell the far vertex is behind the near quad "
                  ~ "and must NOT be pickable; got %d", hoverVertex()));

    // ---- B: THE CHANGE. Only the style moves — no reset, no reload, no ------
    //         camera move, no replayed event. The pointer is parked on the
    //         far corner and the app re-picks every frame.
    setStyle("wireframe");
    assert(hoverVertex() == V_FAR,
           format("B: in a wireframe cell no faces are drawn, so the far "
                  ~ "vertex %d must be pickable at (%d,%d); got %d",
                  V_FAR, fx, fy, hoverVertex()));

    // ---- C: and back, by the same one-term move ---------------------------
    setStyle("shaded");
    assert(hoverVertex() == -1,
           format("C: back in a shaded cell the far vertex must be occluded "
                  ~ "again; got %d", hoverVertex()));

    // ---- D: the click path has NO facing term ------------------------------
    // The side quad is wound away from the eye and nothing is in front of it.
    // Both styles must pick it. If someone wires the resolved `facingTerm`
    // into this path, this is the cell that reddens.
    hoverAt(cam, sx_, sy_);
    assert(hoverVertex() == V_SIDE,
           format("D/shaded: the back-facing but UNOCCLUDED side quad's vertex "
                  ~ "%d must be pickable at (%d,%d) — the click path has no "
                  ~ "facing term (a measured law); got %d",
                  V_SIDE, sx_, sy_, hoverVertex()));
    setStyle("wireframe");
    assert(hoverVertex() == V_SIDE,
           format("D/wireframe: the back-facing side vertex %d must stay "
                  ~ "pickable; got %d", V_SIDE, hoverVertex()));
    setStyle("shaded");

    // ---- E: edges follow vertices, with their own positive control ---------
    setMode("edges");
    assert(getJson("/api/selection")["selType"].str == "edge",
           "the edge picker will not run unless the current type is edge");

    int nex, ney, fex, fey;
    px(Vec3(0, 2, 1),     cam, nex, ney);   // near quad's top edge midpoint
    px(Vec3(0, -0.6, -1), cam, fex, fey);   // far quad's bottom edge midpoint

    hoverAt(cam, nex, ney);
    immutable int nearEdge = hoverEdge();
    assert(nearEdge >= 0,
           format("E positive control: an edge of the near quad must be "
                  ~ "pickable at (%d,%d); got %d", nex, ney, nearEdge));
    auto ne = edgeEnds(nearEdge);
    assert(ne[0] < 4 && ne[1] < 4,
           format("E positive control picked edge %d = (%d,%d), which is not "
                  ~ "a near-quad edge", nearEdge, ne[0], ne[1]));

    hoverAt(cam, fex, fey);
    assert(hoverEdge() == -1,
           format("E/shaded: the far quad's edge is behind the near quad and "
                  ~ "must not be pickable; got %d", hoverEdge()));

    setStyle("wireframe");
    immutable int farEdge = hoverEdge();
    assert(farEdge >= 0,
           format("E/wireframe: the far quad's edge must be pickable at "
                  ~ "(%d,%d); got -1", fex, fey));
    auto fe = edgeEnds(farEdge);
    assert(fe[0] >= 4 && fe[0] < 8 && fe[1] >= 4 && fe[1] < 8,
           format("E/wireframe picked edge %d = (%d,%d), which is not a "
                  ~ "far-quad edge", farEdge, fe[0], fe[1]));
    setStyle("shaded");

    // ---- F: CHARACTERISATION PIN — faces do NOT pick through ---------------
    // Inert by construction (the face pass IS the surface, so no depth
    // pre-pass ever ran for it): this cell cannot separate anything in THIS
    // task, and saying so is the point. It exists to pin the declared scope,
    // and it is expected to go red when the face follow-up lands.
    immutable int faceShaded =
        cast(int)getJson(format("/api/pick?x=%d&y=%d&engine=gpu", fx, fy))["faceIndex"].integer;
    setStyle("wireframe");
    immutable int faceWire =
        cast(int)getJson(format("/api/pick?x=%d&y=%d&engine=gpu", fx, fy))["faceIndex"].integer;
    setStyle("shaded");
    assert(faceShaded == 0 && faceWire == faceShaded,
           format("F: the face pick must still answer the NEAR face (0) in "
                  ~ "both styles — faces picking through is a declared gap, "
                  ~ "not part of this task; got shaded=%d wireframe=%d",
                  faceShaded, faceWire));

    postJson("/api/reset", "");
    settle();
}

// ---------------------------------------------------------------------------
// Cell G — the lasso's vertex half reads the SAME ID buffer, so it moves with
// the policy. (The lasso's POLYGON half does not: the face pass never ran a
// pre-pass, and its separate front-facing cull is untouched — a named
// follow-up, not an accident.)
// ---------------------------------------------------------------------------
unittest {
    auto cam = setupRig();
    setMode("vertices");

    // A band that encloses the four far-quad corners and nothing else: they
    // project ~35 px from the centre, the near quad's corners ~137 px.
    int x0 = int.max, y0 = int.max, x1 = int.min, y1 = int.min;
    foreach (i; 4 .. 8) {
        int x, y;
        px(rigVert(i), cam, x, y);
        if (x < x0) x0 = x;
        if (y < y0) y0 = y;
        if (x > x1) x1 = x;
        if (y > y1) y1 = y;
    }
    x0 -= 12; y0 -= 12; x1 += 12; y1 += 12;
    foreach (i; [0, 1, 2, 3, 8, 9, 10, 11]) {
        int x, y;
        px(rigVert(i), cam, x, y);
        assert(x < x0 || x > x1 || y < y0 || y > y1,
               format("the band [%d..%d]x[%d..%d] also encloses vertex %d at "
                      ~ "(%d,%d) — it would be selected for the wrong reason",
                      x0, x1, y0, y1, i, x, y));
    }

    int[] lassoSelection() {
        playAndWait(lassoLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             x0, y0, x1, y1));
        settle();
        int[] out_;
        foreach (v; getJson("/api/selection")["selectedVertices"].array)
            out_ ~= cast(int)v.integer;
        return out_;
    }

    setStyle("shaded");
    auto shadedSel = lassoSelection();
    assert(shadedSel.length == 0,
           format("G/shaded: the far quad is behind the near one, so a band "
                  ~ "around it must select nothing; got %s", shadedSel));

    setStyle("wireframe");
    auto wireSel = lassoSelection();
    foreach (i; 4 .. 8)
        assert(wireSel.canFind(i),
               format("G/wireframe: the lasso reads the same ID buffer as the "
                      ~ "click, so the far quad's vertex %d must be selected; "
                      ~ "got %s", i, wireSel));
    assert(wireSel.length == 4,
           format("G/wireframe: exactly the four far-quad corners were inside "
                  ~ "the band; got %s", wireSel));

    setStyle("shaded");
    postJson("/api/reset", "");
    settle();
}
