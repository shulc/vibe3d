module topology_redo_law_helpers;

// The executor and the comparison behind the topology-redo law suites (wave plan
// S1a, S1b; fixture `tests/fixtures/topology_redo_law_cells.json`, frozen by the private
// generator `freeze_fixture.py` from the reference captures). One step vocabulary,
// one observation, one comparison for every tool of the topology model — a tool
// differs from another only by its rig (`rigOf`). There is NO branch on a law here.
//
// A cell is a scenario (arm, hauls, navigation keys, attribute writes, commands) and
// a list of checkpoints. At each checkpoint the suite reads OUR product and reduces
// it to the same relations the generator reduced the reference to:
//   image   the EARLIER checkpoints with the same mesh + selection ([] = new)
//   vcount  vertex count, in the reference rig's numbers (ours − our base + its base;
//           a rig whose kernel layer differs scales by Rig.layer)
//   armed   the session's post-mode flag;  on  "tool" | "move" | ""
//   refused a navigation key that moved no history row (Z/R checkpoints only)
//   attrs   the EARLIER checkpoints with the same tool attributes (tool on only)
//   origin  how a haul's step began: the undo top's `stepOrigin` in the fixture's words
//           (opens -> "begin", restart -> "restart", refire -> "none"); "absent" when
//           the top row carries none (task 8930)
//   redoRows redo steps left (rows that do not join the row below)
// A field is either parity (ours == reference) or a declared known divergence
// (ours == the declared `ours`, owner = the slice that closes it). Navigation goes
// only through the keys (`/api/play-events`), never `/api/undo|redo` (plan §4.3).

import http_client : getJson, postJson, frameFence, waitPlaybackProcessed;
import http_command_helpers : commandBody;
import std.algorithm : canFind, countUntil, map, sort;
import std.array : array, join;
import std.conv : to;
import std.format : format;
import std.json;
import std.math : abs;
import std.process : environment;

/// How OUR product plays a reference rig: the reference haul's delta is played as is,
/// from our press point (handle part 0, or the viewport centre) offset like the
/// reference's press from the variant's g1 press.
struct Rig {
    string tool;        // our tool id
    string[] attrs;     // the attributes `attrs` reads
    bool handle;        // press on a handle part (else the viewport centre)
    int handlePart;     // which part `handle` presses (the part the reference haul moves)
    int[2] pressRef;    // the reference press the variant's g1 uses (offsets are relative)
    string[string] attrName;   // logical fixture attribute → our attribute
    int[string] attrComponent; // a logical attribute that is one component of our vector one
    JSONValue mesh;            // rig override (null: the reference rig as frozen)
    string[][string] enumNames; // an enumerated attribute's names by ordinal (rig check)
    string[string] armPreset;  // our attribute → the reference's arm value, written before s00
    bool placesCenter;  // a haul press that misses every handle places the tool's centre:
                        // g1 places it at the reference's placed centre (step `center`)
    bool frameReference;  // the camera frames the reference rig, not the override `mesh`
    bool aimAtSelection;  // each haul: the camera focuses the selected faces' centroid (the
                          // tool's drag anchor), so the press plane is in view
    int[4] deltaMap = [1, 0, 0, 1];  // ours = (m0 dx + m1 dy, m2 dx + m3 dy): the handle's
                                     // screen direction under our camera
    long[2] layer = [1, 1];    // vertices one layer adds: [reference, ours] (vcount scale)
    string dormantDeafDoor;    // the re-arm door after which our dormant haul takes no press
}

/// The autoact rig without its loose vertex 4 (our topology kernels drop a loose vertex,
/// gap row 37): an override like VertexMerge's, so a global selection (`select.invert`)
/// selects the reference's own set. `mode`/`selected` are the variant's.
JSONValue autoactRig(string faces, string mode, string selected) {
    return parseJSON(`{"vertices":[[-0.35,0.25,0.05],[1.45,-0.35,-0.25],[0.45,1.4,0.45],`
        ~ `[-1.2,-0.05,1.15]],"faces":` ~ faces ~ `,"mode":"` ~ mode ~ `","selected":`
        ~ selected ~ `}`);
}

Rig rigOf(string variant) {
    Rig r;
    final switch (variant) {
    case "inset":
        r.tool = "mesh.polyInsetTool"; r.attrs = ["inset"]; r.pressRef = [430, 561];
        r.attrName = ["inset": "inset"];
        break;
    case "poly_extrude":
        r.tool = "poly.extrude"; r.attrs = ["distance", "shiftX", "shiftY", "shiftZ"];
        r.handle = true; r.pressRef = [640, 170];
        r.attrName = ["shiftY": "shiftY"];   // 8960 `doapply_after_sa_pextrude`
        break;
    case "smooth":
    case "thicken":
        r.tool = variant == "smooth" ? "mesh.smoothShiftTool" : "mesh.thickenTool";
        r.attrs = ["shift", "scale", "maxAngle", "thicken", "sharp"];
        r.handle = true; r.pressRef = [595, 501];
        r.attrName = ["shift": "shift"];
        break;
    case "vertex_merge":
        r.tool = "vert.merge"; r.attrs = ["dist"]; r.pressRef = [430, 561];
        // our merge drops loose vertices (gap row 37), so the three near-coincident
        // vertices of the reference rig carry one far triangle each: a merge still
        // removes exactly the merged vertices (vcount is compared from the rig base)
        r.mesh = parseJSON(`{"vertices":[[-0.35,0.25,0.05],[-0.348,0.25,0.05],`
            ~ `[-0.3444,0.25,0.05],[-0.9,-0.5,0.05],[-0.6,-0.6,0.05],[0.2,-0.5,0.05],`
            ~ `[0.5,-0.3,0.05],[-0.2,0.9,0.05],[0.2,0.9,0.05]],`
            ~ `"faces":[[0,3,4],[1,5,6],[2,7,8]],"mode":"vertices","selected":[0,1,2]}`);
        break;
    // autoact family (S1b): the reference rig less its loose vertex 4 (`autoactRig`;
    // `vcount` is compared from the rig base). The part each reference haul moves — EdgeBevel width,
    // VertexBevel inset, VertexExtrude inset (= our width; shift stays 0); EdgeExtrude
    // moves width AND shift, which is our off-handle 2-axis drag (dx width, -dy extrude)
    case "edge_bevel":
        r.tool = "edge.bevel"; r.attrs = ["width", "roundLevel"];
        r.handle = true; r.handlePart = 0; r.pressRef = [596, 614];
        r.deltaMap = [0, -1, 1, 0];   // our width arrow points down on screen
        r.attrName = ["value": "width"];
        r.mesh = autoactRig(`[[0,1,2],[0,2,3]]`, "edges", `[[0,2]]`);
        break;
    case "edge_extrude":
        r.tool = "edge.extrude"; r.attrs = ["extrude", "width"]; r.pressRef = [640, 170];
        r.mesh = autoactRig(`[[0,1,2],[0,2,3]]`, "edges", `[[0,2]]`);
        // measured: framed on the override, the off-handle press of
        // nav_undo_restart_eextrude's last haul changes nothing — frame the reference rig
        r.frameReference = true;
        break;
    case "vertex_bevel":
        r.tool = "mesh.vertexBevel"; r.attrs = ["inset"];
        r.handle = true; r.handlePart = 0; r.pressRef = [489, 546];
        r.deltaMap = [0, -1, 1, 0];   // our inset arrow points down on screen
        r.mesh = autoactRig(`[[0,1,2],[0,2,3]]`, "vertices", `[0]`);
        break;
    case "vertex_extrude":
        r.tool = "mesh.vertexExtrude"; r.attrs = ["shift", "width"];
        r.handle = true; r.handlePart = 1; r.pressRef = [500, 472];
        // our kernel extrudes only a vertex whose every edge has two faces: the face
        // 1-0-3 closes the fan of the selected vertex 0 (the reference extrudes it open);
        // it then builds TWO rings per layer (6 vertices) where the reference builds one (3)
        r.mesh = autoactRig(`[[0,1,2],[0,2,3],[1,0,3]]`, "vertices", `[0]`);
        r.layer = [3, 6];
        break;
    // generators family (S1b): every haul presses the viewport centre (a press that
    // misses the handles places the centre or drags the offset — the reference haul
    // writes the centre or the offset the same way)
    case "mirror":
    case "mirror_wide":
        r.tool = "mesh.mirrorTool"; r.attrs = ["axis", "center", "angle"]; r.pressRef = [430, 561];
        r.attrName = ["axis": "axis"];
        r.enumNames = ["axis": ["X", "Y", "Z"]];
        r.attrName["centerY"] = "center"; r.attrComponent["centerY"] = 1;   // 8960 `cenY`
        r.armPreset = ["axis": "Y"];   // every mirror cell's raw s01: `axis: 1`
        r.placesCenter = true;         // the weld at x = -0.35 (vertex 1) needs the same centre
        break;
    case "radial_array":
        r.tool = "mesh.radialArrayTool"; r.attrs = ["count", "axis", "center", "angle", "offset"];
        r.pressRef = [430, 561];
        // measured: re-armed through the SCRIPT door after W and the navigation, our
        // RadialArray draws no handle and takes no press (no step, no attribute) — its
        // dormant haul cannot write (PLAN-FINDING of S1b; the UI door takes the press)
        r.dormantDeafDoor = "script";
        break;
    case "array":
        r.tool = "mesh.arrayTool"; r.attrs = ["numX", "numY", "numZ", "offX", "offY", "offZ"];
        r.pressRef = [430, 561];
        r.attrName = ["countX": "numX"];
        break;
    case "clone":
        r.tool = "mesh.clone"; r.attrs = ["num", "offX", "offY", "offZ"]; r.pressRef = [430, 561];
        // the reference arms with 61 copies (raw s01 `num: 61`); preset before the arm, our
        // arm builds nothing and g1 builds the 61 copies (5 + 305 vertices, as there). The
        // dormant haul's anchor is then the 61 selected copies, far out of the rig's view:
        // without the aim our plane projection refuses the press
        r.armPreset = ["num": "61"];
        r.aimAtSelection = true;
        break;
    }
    return r;
}

// ------------------------------------------------------------------ transport

private void cmdOk(string path, string line, string ctx) {
    auto r = postJson(path, line);
    assert(r["status"].str == "ok" || r["status"].str == "success",
        ctx ~ ": " ~ path ~ " '" ~ line ~ "' failed: " ~ r.toString);
}

private void settle() { frameFence(null, 2); }

private string viewportHead() {
    auto c = getJson("/api/camera");
    return format(`{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}`
        ~ "\n" ~ `{"t":0.000,"type":"PACE","mode":"frames"}` ~ "\n",
        c["vpX"].integer, c["vpY"].integer, c["width"].integer, c["height"].integer);
}

private void play(string lines) {
    auto r = postJson("/api/play-events", viewportHead() ~ lines);
    assert(r["status"].str == "success", "play-events failed: " ~ r.toString);
    waitPlaybackProcessed();
    settle();
}

private void key(int sym, int mod) {
    play(format(`{"t":10.000,"type":"SDL_KEYDOWN","sym":%d,"scan":0,"mod":%d,"repeat":0}` ~ "\n"
        ~ `{"t":20.000,"type":"SDL_KEYUP","sym":%d,"scan":0,"mod":%d,"repeat":0}` ~ "\n",
        sym, mod, sym, mod));
}

private void drag(int x0, int y0, int dx, int dy, int btn) {
    enum steps = 12;
    string s = format(`{"t":30.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n"
        ~ `{"t":50.000,"type":"SDL_MOUSEBUTTONDOWN","btn":%d,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        x0, y0, btn, x0, y0);
    int lx = x0, ly = y0;
    foreach (i; 1 .. steps + 1) {
        const x = x0 + cast(int)(cast(double) dx * i / steps);
        const y = y0 + cast(int)(cast(double) dy * i / steps);
        s ~= format(`{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":%d,"mod":0}` ~ "\n",
            50.0 + 50.0 * i, x, y, x - lx, y - ly, 1 << (btn - 1));
        lx = x; ly = y;
    }
    s ~= format(`{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":%d,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        50.0 + 50.0 * (steps + 1), btn, lx, ly);
    play(s);
}

private void tap(int x, int y, int btn) {
    play(format(`{"t":30.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n"
        ~ `{"t":50.000,"type":"SDL_MOUSEBUTTONDOWN","btn":%d,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n"
        ~ `{"t":100.000,"type":"SDL_MOUSEBUTTONUP","btn":%d,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        x, y, btn, x, y, btn, x, y));
}

private double num(JSONValue v) {
    return v.type == JSONType.integer ? cast(double) v.integer
         : v.type == JSONType.uinteger ? cast(double) v.uinteger
         : v.type == JSONType.true_ ? 1 : v.type == JSONType.false_ ? 0 : v.floating;
}

// ------------------------------------------------------------------ the rig

/// Reset, load the cell's rig, select, frame, clear history. Returns our base vcount.
long setupCell(const JSONValue cell, const Rig rig) {
    const ctx = "cell " ~ cell["id"].str;
    cmdOk("/api/command", commandBody("scene.reset"), ctx);
    cmdOk("/api/command", "workplane.reset", ctx);
    JSONValue m = rig.mesh.type == JSONType.object ? rig.mesh : cell["rig"];
    cmdOk("/api/command", commandBody("scene.loadMesh",
        `{"vertices":` ~ m["vertices"].toString ~ `,"faces":` ~ m["faces"].toString ~ `}`), ctx);
    // an edge is frozen as its vertex pair; our index is the pair's place in our edge list
    string sel = m["selected"].toString;
    if (m["mode"].str == "edges") {
        const edges = getJson("/api/model")["edges"].array;
        long[] idx;
        foreach (pr; m["selected"].array) {
            const a = pr[0].integer, b = pr[1].integer;
            const k = edges.countUntil!(e => (e[0].integer == a && e[1].integer == b)
                || (e[0].integer == b && e[1].integer == a));
            assert(k >= 0, format("rig VOID %s: our mesh has no edge %d-%d", ctx, a, b));
            idx ~= k;
        }
        sel = JSONValue(idx).toString;
    }
    cmdOk("/api/command", commandBody("mesh.select",
        format(`{"mode":"%s","indices":%s}`, m["mode"].str, sel)), ctx);
    // an oblique view on the rig's centre: every handle off-axis, the whole rig in frame
    // (`Rig.frameReference`: the reference rig's centre, though an override is loaded)
    const framed = rig.frameReference ? cell["rig"] : m;
    double[3] c = 0;
    foreach (v; framed["vertices"].array)
        foreach (k; 0 .. 3) c[k] += num(v[k]) / framed["vertices"].array.length;
    cmdOk("/api/camera", format(`{"azimuth":0.5,"elevation":0.4,"distance":7,`
        ~ `"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`, c[0], c[1], c[2]), ctx);
    // the reference's arm attributes our arm lacks: written on an armed, untouched tool
    // and dropped (our tools keep their attributes across a drop and re-arm)
    if (rig.armPreset.length) {
        cmdOk("/api/command", "tool.set " ~ rig.tool ~ " on", ctx);
        foreach (a, v; rig.armPreset) {
            cmdOk("/api/command", "tool.attr " ~ rig.tool ~ " " ~ a ~ " " ~ v, ctx);
            const r = postJson("/api/command", "tool.attr " ~ rig.tool ~ " " ~ a ~ " ?");
            const got = r["value"].type == JSONType.string ? r["value"].str : r["value"].toString;
            assert(got == v, format("rig VOID %s: the arm preset %s reads %s, written %s",
                ctx, a, r["value"].toString, v));
        }
        cmdOk("/api/command", "tool.set " ~ rig.tool ~ " off", ctx);
    }
    centerPlaced = false;
    cmdOk("/api/command", "history.clear", ctx);
    settle();
    const base = cast(long) getJson("/api/model")["vertices"].array.length;
    // `vcount` is compared from the rig base (ours − our base + its base), so s00 equals
    // the reference by construction: on the reference's own rig the bases must agree
    // (only an override rig — VertexMerge, the autoact family; gap 37 — may differ)
    if (rig.mesh.type != JSONType.object) {
        const baseRef = cell["points"][0]["fields"]["vcount"]["ref"].integer;
        assert(base == baseRef, format("rig VOID %s: our base holds %d vertices, the reference's %d",
            ctx, base, baseRef));
    }
    return base;
}

/// Where a haul presses. `aim` (generator, 8980 findings §17.1) overrides the rig's
/// default: "handle" — the press the reference aimed at the drawn handle (no pixel frozen:
/// exactly on our handle part); "free" — a haul the reference made with no handle drawn
/// (the viewport centre plus the press offset, even on a handle rig).
private void pressPoint(const Rig rig, const JSONValue step, out int x, out int y) {
    auto cam = getJson("/api/camera");
    double bx = cam["vpX"].integer + cam["width"].integer / 2;
    double by = cam["vpY"].integer + cam["height"].integer / 2;
    const aim = "aim" in step ? step["aim"].str : "";
    if (aim == "handle") {
        const h = getJson("/api/tool/handles")["handles"];
        bool found;
        if (h.type == JSONType.object)
            foreach (p; h["parts"].array)
                if (p["part"].integer == rig.handlePart && p["screen"].type == JSONType.array) {
                    x = cast(int) num(p["screen"][0]); y = cast(int) num(p["screen"][1]);
                    found = true;
                }
        assert(found, format("rig VOID: %s draws no handle part %d for the aimed haul",
            rig.tool, rig.handlePart));
        return;
    }
    if (rig.handle && aim != "free") {
        auto h = getJson("/api/tool/handles")["handles"];
        // no handle drawn at all (the navigation took the tool's gizmo away; reached in
        // the autoact family): the press stays at the viewport centre — a tool without a
        // drawn handle hits no part wherever it is pressed (measured: same relations)
        const drawn = h.type == JSONType.object;
        bool found;
        if (drawn)
            foreach (p; h["parts"].array)
                if (p["part"].integer == rig.handlePart && p["screen"].type == JSONType.array) {
                    bx = num(p["screen"][0]); by = num(p["screen"][1]); found = true;
                }
        assert(found || !drawn, format("rig: %s handle part %d is not on screen",
            rig.tool, rig.handlePart));
    }
    x = cast(int)(bx + num(step["press"][0]) - rig.pressRef[0]);
    y = cast(int)(by + num(step["press"][1]) - rig.pressRef[1]);
}

/// The window-pixel box [x0, y0, x1, y1] of the current mesh's vertices under the
/// matrices the viewport renders with (`/api/camera`; column-major, as math.d mulMV).
private double[4] meshScreenBox(const JSONValue cam) {
    double[16] v, p;
    foreach (i; 0 .. 16) { v[i] = num(cam["viewMatrix"][i]); p[i] = num(cam["projMatrix"][i]); }
    double[4] mul(const double[16] m, const double[4] a) {
        double[4] r;
        foreach (k; 0 .. 4) r[k] = m[k] * a[0] + m[4 + k] * a[1] + m[8 + k] * a[2] + m[12 + k] * a[3];
        return r;
    }
    double[4] box = [double.max, double.max, -double.max, -double.max];
    const verts = getJson("/api/model")["vertices"].array;
    assert(verts.length > 0, "rig: the mesh is empty at the right tap");
    foreach (w; verts) {
        const c = mul(p, mul(v, [num(w[0]), num(w[1]), num(w[2]), 1.0]));
        assert(c[3] > 0, "rig: a vertex lies behind the camera at the right tap");
        const sx = (c[0] / c[3] * 0.5 + 0.5) * cam["width"].integer + cam["vpX"].integer;
        const sy = (0.5 - c[1] / c[3] * 0.5) * cam["height"].integer + cam["vpY"].integer;
        if (sx < box[0]) box[0] = sx;
        if (sy < box[1]) box[1] = sy;
        if (sx > box[2]) box[2] = sx;
        if (sy > box[3]) box[3] = sy;
    }
    return box;
}

/// The first haul of the cell placed the centre (`Rig.placesCenter`; reset by setupCell).
private bool centerPlaced;

/// Half the reference's 0.05 placement snap: our placed centre must round to its centre.
enum double kCenterSnapHalf = 0.025;

/// `Rig.placesCenter`, g1: look at the reference's centre T from a direction perpendicular
/// to T − C0 (C0 our current centre), so the viewport centre's ray meets our press plane
/// (screen-facing, through C0) at T. T is the reference's centre AFTER its g1 drag, so our g1
/// ends at the reference's post-haul centre by construction: these cells measure the session
/// laws downstream of g1 and do not test the placement law itself (findings §12-§13).
private void aimAtCenter(const Rig rig, const JSONValue step, string ctx) {
    import std.math : atan, cos, sin;
    assert("center" in step, "rig VOID " ~ ctx ~ "/" ~ step["label"].str
        ~ ": the fixture freezes no reference centre for the first haul");
    const c0 = postJson("/api/command", "tool.attr " ~ rig.tool ~ " center ?")["value"];
    double[3] t, v;
    foreach (k; 0 .. 3) { t[k] = num(step["center"][k]); v[k] = t[k] - num(c0[k]); }
    enum double az = 0.5;
    assert(abs(v[1]) > 1e-3, "rig VOID " ~ ctx ~ ": the reference centre is level with ours");
    const el = atan(-(v[0] * sin(az) + v[2] * cos(az)) / v[1]);
    cmdOk("/api/camera", format(`{"azimuth":%.17g,"elevation":%.17g,"distance":7,`
        ~ `"focus":{"x":%.17g,"y":%.17g,"z":%.17g}}`, az, el, t[0], t[1], t[2]), ctx);
    settle();
}

/// `Rig.aimAtSelection`: focus the camera (same orbit) on the selected faces' centroid.
private void aimAtSelected(string ctx) {
    const m = getJson("/api/model");
    bool[long] vs;
    foreach (f; getJson("/api/selection")["selectedFaces"].array)
        foreach (v; m["faces"][cast(size_t) f.integer].array) vs[v.integer] = true;
    assert(vs.length, "rig VOID " ~ ctx ~ ": no selected face to aim at");
    double[3] c = 0;
    foreach (v, _; vs)
        foreach (k; 0 .. 3) c[k] += num(m["vertices"][cast(size_t) v][k]) / vs.length;
    cmdOk("/api/camera", format(`{"azimuth":0.5,"elevation":0.4,"distance":7,`
        ~ `"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`, c[0], c[1], c[2]), ctx);
    settle();
}

/// Run one step of the scenario (the generator's lexicon, plan §4.7).
void runStep(const JSONValue step, const Rig rig, string ctx) {
    const op = step["op"].str;
    switch (op) {
    case "skip": return;               // a Z the reference's zguard did not send (PF-1)
    case "arm":
        cmdOk(step["door"].str == "ui" ? "/api/command?origin=ui" : "/api/command",
            "tool.set " ~ rig.tool ~ " on", ctx);
        settle();
        return;
    case "haul": {
        const place = rig.placesCenter && !centerPlaced;
        if (place) aimAtCenter(rig, step, ctx);
        if (rig.aimAtSelection) aimAtSelected(ctx);
        int x, y;
        pressPoint(rig, step, x, y);
        if ("aim" in step) {
            // rig precondition: an aimed press hovers the handle, a free one hovers none
            play(format(`{"t":10.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,`
                ~ `"state":0,"mod":0}` ~ "\n", x, y));
            const h = getJson("/api/tool/handles")["handles"];
            const hot = h.type == JSONType.object ? h["hot"].integer : -1;
            assert(step["aim"].str == "handle" ? hot == rig.handlePart : hot < 0,
                format("rig VOID %s/%s: the %s press (%d, %d) hovers part %d", ctx,
                    step["label"].str, step["aim"].str, x, y, hot));
        }
        const rx = num(step["delta"][0]), ry = num(step["delta"][1]);
        const m = rig.deltaMap;
        const dx = m[0] * rx + m[1] * ry, dy = m[2] * rx + m[3] * ry;
        drag(x, y, cast(int) dx, cast(int) dy, step["button"].str == "middle" ? 2 : 1);
        if (place) {
            centerPlaced = true;
            const c = postJson("/api/command", "tool.attr " ~ rig.tool ~ " center ?")["value"];
            foreach (k; 0 .. 3)
                assert(abs(num(c[k]) - num(step["center"][k])) <= kCenterSnapHalf + 1e-9,
                    format("rig VOID %s/%s: our g1 centre %s is not the reference's %s (to its "
                        ~ "0.05 placement snap)", ctx, step["label"].str, c.toString,
                        step["center"].toString));
        }
        return;
    }
    case "key":
        const k = step["key"].str;
        if (k == "Z") key(122, 64);
        else if (k == "R") key(122, 65);
        else { assert(k == "W", ctx ~ ": unknown key " ~ k); key(119, 0); }
        return;
    case "enter":
        key(13, 0);
        return;
    case "attr": {
        const name = step["name"].str;
        assert(name in rig.attrName, ctx ~ ": rig has no attribute for " ~ name);
        const comp = name in rig.attrComponent;
        if (comp) {
            // one component of our vector attribute: the others keep their current value
            assert(step["door"].str == "script", ctx ~ ": a component write on the "
                ~ step["door"].str ~ " door has no lexicon entry");
            auto v = postJson("/api/command", "tool.attr " ~ rig.tool ~ " " ~ rig.attrName[name]
                ~ " ?")["value"].array.map!(e => num(e)).array;
            v[*comp] = num(step["value"]);
            cmdOk("/api/command", format(`{"id":"tool.attr","params":{"_positional":["%s","%s",`
                ~ `[%.9g,%.9g,%.9g]]}}`, rig.tool, rig.attrName[name], v[0], v[1], v[2]), ctx);
        } else {
            const line = format("tool.attr %s %s %.9g", rig.tool, rig.attrName[name], num(step["value"]));
            // plan §4.7 R4 lexicon: the panel = an interactive script write; the script door
            // = /api/command. `?origin=ui tool.attr` is NOT used (a scripted value, §4.7 R6).
            if (step["door"].str == "panel") cmdOk("/api/script?interactive=true", line, ctx);
            else cmdOk("/api/command", line, ctx);
        }
        settle();
        // rig precondition (plan S1b R5): the write changed the attribute — a closed-
        // operation panel write leaves the image alone (Pc-own), never the attribute
        const r = postJson("/api/command", "tool.attr " ~ rig.tool ~ " " ~ rig.attrName[name] ~ " ?");
        assert(r["status"].str == "ok", ctx ~ ": read " ~ name ~ ": " ~ r.toString);
        const want = num(step["value"]);
        const v = r["value"];
        const got = comp ? num(v[*comp]) : v.type == JSONType.string
            ? rig.enumNames[rig.attrName[name]].countUntil(v.str) : num(v);
        assert(abs(got - want) <= 1e-6 * (1 + abs(want)), format("rig VOID %s: attr:%s did not "
            ~ "change the attribute (%s reads %s, written %.9g)", ctx, step["door"].str, name,
            v.toString, want));
        return;
    }
    case "cmd":
        cmdOk(step["door"].str == "ui" ? "/api/command?origin=ui" : "/api/command",
            step["command"].str, ctx);
        settle();
        return;
    case "reset":
        cmdOk(step["door"].str == "ui" ? "/api/command?origin=ui" : "/api/command",
            "tool.reset", ctx);
        settle();
        return;
    case "drop":
        cmdOk(step["door"].str == "ui" ? "/api/command?origin=ui" : "/api/command",
            "tool.set " ~ rig.tool ~ " off", ctx);
        settle();
        return;
    case "rclick":
    case "mtap": {
        // an empty background point of the rig (right tap; middle tap): the viewport's
        // top-left corner region, checked against the mesh's projected screen box at the
        // moment of the tap
        auto cam = getJson("/api/camera");
        const x = cast(int) cam["vpX"].integer + 24, y = cast(int) cam["vpY"].integer + 24;
        const box = meshScreenBox(cam);
        const which = op == "rclick" ? "right" : "middle";
        assert(x < box[0] || x > box[2] || y < box[1] || y > box[3],
            format("rig VOID %s: the %s tap (%d, %d) lies inside the mesh's screen box %s",
                ctx, which, x, y, box));
        tap(x, y, op == "rclick" ? 3 : 2);
        return;
    }
    default:
        assert(false, ctx ~ ": the executor has no step " ~ op);
    }
}

// ------------------------------------------------------------------ observation

struct Obs {
    string label;
    string image;     // mesh + selection, the identity the image classes compare
    long vcount;      // raw, ours
    bool armed;
    string on;
    string attrs;     // canonical attribute values; null when the tool is not on
    string origin;    // the undo top's step origin, fixture words ("absent": none)
    long undoRows, redoRows, redoSteps;
}

enum ulong kJoinsBelow = 1UL << 14;   // command_history.d HistoryFlags.JoinsBelow

Obs observe(string label, const Rig rig) {
    Obs o;
    o.label = label;
    auto m = getJson("/api/model");
    auto s = getJson("/api/selection");
    o.image = m["vertices"].toString ~ "|" ~ m["faces"].toString ~ "|"
        ~ s["selectedVertices"].toString ~ s["selectedEdges"].toString ~ s["selectedFaces"].toString;
    o.vcount = cast(long) m["vertices"].array.length;
    auto st = getJson("/api/tool/state");
    if (auto ss = "session" in st)
        if (auto a = "armed" in *ss) o.armed = a.type == JSONType.true_;
    const id = getJson("/api/input/context")["tool"].str;
    o.on = id == rig.tool ? "tool" : id == "move" ? "move" : id.length ? "other:" ~ id : "";
    if (o.on == "tool") {
        string[] parts;
        foreach (a; rig.attrs) {
            auto r = postJson("/api/command", "tool.attr " ~ rig.tool ~ " " ~ a ~ " ?");
            assert(r["status"].str == "ok", "read " ~ a ~ ": " ~ r.toString);
            const v = r["value"];
            parts ~= v.type == JSONType.string || v.type == JSONType.array
                ? a ~ "=" ~ v.toString : format("%s=%.6g", a, num(v));
        }
        o.attrs = parts.join(";");
    }
    auto h = getJson("/api/history");
    o.origin = "absent";
    if (h["undo"].array.length)
        if (auto so = "stepOrigin" in h["undo"].array[$ - 1])
            o.origin = so.str == "opens" ? "begin" : so.str == "refire" ? "none" : so.str;
    o.undoRows = cast(long) h["undo"].array.length;
    o.redoRows = cast(long) h["redo"].array.length;
    foreach (row; h["redo"].array)
        if ((cast(ulong) row["flags"].integer & kJoinsBelow) == 0) ++o.redoSteps;
    return o;
}

// ------------------------------------------------------------------ relations

private string shortLabel(string label) {
    const i = label.countUntil('_');
    return i < 0 ? label : label[0 .. i];
}

/// The generator's class rule (§4.7 R7 rule 1) over our observations: the EARLIER
/// checkpoints with an equal value; null values take part in no class.
JSONValue classOf(const Obs[] obs, size_t i, string delegate(const Obs) value) {
    string[] eq;
    const v = value(obs[i]);
    foreach (j; 0 .. i) {
        const w = value(obs[j]);
        if (w !is null && w == v) eq ~= shortLabel(obs[j].label);
    }
    return JSONValue(eq);
}

/// Our relation for one field of checkpoint i; `navKind` is "Z"/"R" for a navigation
/// checkpoint (refused is defined only there).
JSONValue ourField(string field, const Obs[] obs, size_t i, long baseOurs, long baseRef,
                   const Obs* before, const long[2] layer = [1, 1]) {
    switch (field) {
    case "image": return classOf(obs, i, (const Obs o) => o.image);
    case "vcount": {
        // in the reference's vertices per layer (Rig.layer); a count that is not a whole
        // number of our layers stays visible as a fraction
        const d = (obs[i].vcount - baseOurs) * layer[0];
        if (d % layer[1]) return JSONValue(format("%d+%d/%d", baseRef, d, layer[1]));
        return JSONValue(d / layer[1] + baseRef);
    }
    case "armed": return JSONValue(obs[i].armed);
    case "on": return JSONValue(obs[i].on);
    case "attrs":
        if (obs[i].attrs is null) return JSONValue("unreadable");
        return classOf(obs, i, (const Obs o) => o.attrs);
    case "refused":
        assert(before !is null);
        return JSONValue(before.undoRows == obs[i].undoRows && before.redoRows == obs[i].redoRows);
    case "origin": return JSONValue(obs[i].origin);
    case "redoRows": return JSONValue(obs[i].redoSteps);
    default: assert(false, "unknown field " ~ field);
    }
}

// ------------------------------------------------------------------ one cell

struct CellRun {
    Obs[] obs;            // one per checkpoint, s00 first
    long baseOurs;
    long[2] layer = [1, 1];
}

/// Play the whole cell and observe every checkpoint.
CellRun playCell(const JSONValue cell) {
    const rig = rigOf(cell["variant"].str);
    CellRun run;
    run.baseOurs = setupCell(cell, rig);
    run.layer = rig.layer;
    run.obs ~= observe("s00_prearm", rig);
    foreach (step; cell["steps"].array) {
        const label = step["label"].str;
        runStep(step, rig, "cell " ~ cell["id"].str ~ "/" ~ label);
        if (step["op"].str == "skip") continue;
        run.obs ~= observe(label, rig);
    }
    return run;
}

/// Whether the rig demands that the last haul of `_dormant` cell `id` change the
/// attributes: only where the reference's own haul did (its frozen `attrs` class
/// there does not hold the checkpoint before it). Where the reference writes the same
/// value the demand is a rig the reference itself would fail (task 9020, law 4).
/// Floor over the fixture: 11 cells demand, 10 write the same value (one cell's haul
/// freezes no attributes).
bool dormantHaulDemand(const JSONValue fixture, string id) {
    size_t nDemand, nRefSame;
    bool demand;
    foreach (c; fixture["cells"].array) {
        const cid = c["id"].str;
        if (!canFind(cid, "_dormant") || (cid.length >= 7 && cid[0 .. 7] == "dormant")) continue;
        string last;
        foreach (s; c["steps"].array) if (s["op"].str == "haul") last = s["label"].str;
        const pts = c["points"].array;
        size_t k;
        while (k < pts.length && pts[k]["label"].str != last) ++k;
        assert(k > 0 && k < pts.length, "fixture: " ~ cid ~ " has no checkpoint " ~ last);
        auto f = "attrs" in pts[k]["fields"].object;
        if (f is null) continue;
        const same = classHas(*f, shortLabel(pts[k - 1]["label"].str));
        if (same) ++nRefSame; else ++nDemand;
        if (cid == id) demand = !same;
    }
    assert(nDemand == 11 && nRefSame == 10, format("fixture: the dormant hauls' rig census is "
        ~ "%d demanding / %d writing the reference's same value, frozen at 11 / 10",
        nDemand, nRefSame));
    return demand;
}

/// Rig preconditions (plan §5 S1a п.4): a run that fails one is VOID, not a verdict.
/// `dormantDemand`: `dormantHaulDemand` of the cell.
void checkRig(const JSONValue cell, const CellRun run, bool dormantDemand) {
    const id = cell["id"].str;
    const steps = cell["steps"].array;
    size_t at(string label) {
        foreach (k, o; run.obs) if (o.label == label) return k;
        assert(false, "rig: no checkpoint " ~ label);
    }
    string[] hauls;
    foreach (s; steps) if (s["op"].str == "haul") hauls ~= s["label"].str;
    bool starts(string p) { return id.length >= p.length && id[0 .. p.length] == p; }

    if (starts("inset_direct") || starts("thicken_direct") || starts("pextrude_direct")
        || starts("smooth_direct")) {
        const k = at(hauls[1]);
        assert(run.obs[k].image != run.obs[k - 1].image,
            "rig VOID " ~ id ~ ": g2 did not change the image");
    }
    if (starts("vmerge_discrim")) {
        const k1 = at(hauls[0]), k2 = at(hauls[1]);
        assert(run.obs[k1].vcount < run.baseOurs,
            "rig VOID " ~ id ~ ": the first haul merged nothing");
        assert(run.obs[k2].attrs != run.obs[k1].attrs,
            "rig VOID " ~ id ~ ": the signed second haul left the distance unchanged");
    }
    if (canFind(id, "_attrs_")) {
        const k = at(hauls[0]);
        assert(run.obs[k].attrs != run.obs[k - 1].attrs,
            "rig VOID " ~ id ~ ": g1 attributes equal the arm's");
    }
    string rearmDoor;
    foreach (s; steps) if (s["op"].str == "arm") rearmDoor = s["door"].str;
    if (canFind(id, "_dormant") && !starts("dormant")) {
        const k = at(hauls[$ - 1]);
        if (rearmDoor != rigOf(cell["variant"].str).dormantDeafDoor) {
            if (dormantDemand)
                assert(run.obs[k].attrs != run.obs[k - 1].attrs,
                    "rig: dormant haul changed no attribute in " ~ id);
        }
        else    // self-expiring: the measured deaf door (gap row 487) writes nothing
            assert(run.obs[k].attrs == run.obs[k - 1].attrs
                && run.obs[k].undoRows == run.obs[k - 1].undoRows,
                "rig: " ~ id ~ ": dormant haul now writes — drop dormantDeafDoor (S6)");
    }
    if (starts("dormant2_")) {
        const k = at(hauls[$ - 1]);
        assert(run.obs[k].attrs != run.obs[k - 1].attrs,
            "rig VOID " ~ id ~ ": g'' attributes equal g'");
    }
    if (starts("nav_") || starts("rebegin_")) {
        const k = at(hauls[$ - 1]);
        assert(run.obs[k].image != run.obs[k - 1].image,
            "rig VOID " ~ id ~ ": the last haul did not change the image");
    }
    foreach (s; steps) {
        const lab = s["label"].str;
        if (s["op"].str == "haul" && s["button"].str == "middle") {
            const k = at(lab);
            assert(run.obs[k].vcount > run.obs[k - 1].vcount,
                "rig VOID " ~ id ~ "/" ~ lab ~ ": the restart haul did not stack (no restart)");
        }
        if (s["op"].str == "rclick") {
            const k = at(lab);
            assert(run.obs[k].image == run.obs[k - 1].image,
                "rig VOID " ~ id ~ "/" ~ lab ~ ": the right tap hit something (image or selection moved)");
        }
        if (s["op"].str == "attr" && s["door"].str == "panel" && "openPanel" in s) {
            const k = at(lab);
            assert(run.obs[k].image != run.obs[k - 1].image,
                "rig VOID " ~ id ~ "/" ~ lab ~ ": attr:panel did not change the image");
        }
    }
}

/// The comparison: every frozen field of every checkpoint, parity or declared.
void compareCell(const JSONValue cell, const CellRun run) {
    const id = cell["id"].str;
    const baseRef = cell["points"][0]["fields"]["vcount"]["ref"].integer;
    assert(cell["points"].array.length == run.obs.length,
        format("cell %s: %d checkpoints frozen, %d observed", id,
            cell["points"].array.length, run.obs.length));
    // An unjudged checkpoint (`attrsUnjudged`: its attributes are not frozen) is no
    // classmate of anyone's attributes, ours as the reference's (plan §16.6 G3 (b)).
    bool[string] unjudged;
    foreach (p; cell["points"].array)
        if ("attrsUnjudged" in p) unjudged[shortLabel(p["label"].str)] = true;
    foreach (i, p; cell["points"].array) {
        const lab = p["label"].str;
        assert(lab == run.obs[i].label, "cell " ~ id ~ ": checkpoint order " ~ lab);
        foreach (field, f; p["fields"].object) {
            auto ours = ourField(field, run.obs, i, run.baseOurs, baseRef,
                i ? &run.obs[i - 1] : null, run.layer);
            if (field == "attrs" && ours.type == JSONType.array && unjudged.length) {
                JSONValue[] kept;
                foreach (m; ours.array) if (m.str !in unjudged) kept ~= m;
                ours = JSONValue(kept);
            }
            const law = "law" in f ? f["law"].str : "-";
            if (auto declared = "ours" in f) {
                // closed first: ours now carries the reference relation (a declared value
                // that IS the reference — a class-owned point — cannot close this way)
                if (auto r = "ref" in f)
                    assert(declared.toString != r.toString || field == "image",
                        format("cell %s/%s.%s: the fixture declares a divergence equal to the "
                            ~ "reference %s (only the class rule may, plan §4.7 R8)", id, lab,
                            field, r.toString));
                if (auto r = "ref" in f)
                    assert(declared.toString == r.toString || !sameRelation(ours, *r),
                        format("divergence closed or moved: %s/%s.%s law %s — flip to parity in %s"
                            ~ " (ours %s now equals the reference)", id, lab, field, law,
                            f["owner"].str, ours.toString));
                assert(ours.toString == declared.toString,
                    format("divergence closed or moved: %s/%s.%s law %s — flip to parity in %s"
                        ~ " (ours %s, declared %s, reference %s)", id, lab, field, law,
                        f["owner"].str, ours.toString, declared.toString, refText(f)));
            } else if (auto any = "refIn" in f) {
                assert(any.array.canFind!(a => a.toString == ours.toString),
                    format("cell %s/%s.%s law %s: ours %s is not in the reference's %s",
                        id, lab, field, law, ours.toString, any.toString));
            } else {
                assert(sameRelation(ours, f["ref"]),
                    format("cell %s/%s.%s law %s: parity broken — ours %s, reference %s",
                        id, lab, field, law, ours.toString, f["ref"].toString));
            }
        }
    }
}

/// Two relations are the same when equal as values; a class (array of checkpoint
/// names) compares as a SET — equal members, not one shared name (§4.7 R7 rule 1).
bool sameRelation(const JSONValue a, const JSONValue b) {
    if (a.type == JSONType.array && b.type == JSONType.array) {
        auto x = a.array.map!(v => v.str).array.sort.array;
        auto y = b.array.map!(v => v.str).array.sort.array;
        return x == y;
    }
    return a.toString == b.toString;
}

private string refText(const JSONValue f) {
    if (auto r = "ref" in f) return r.toString;
    return f["refIn"].toString;
}

/// The dump the generator reads to declare our side (VIBE3D_TOPO_REDO_DUMP).
void dumpCell(const JSONValue cell, const CellRun run, string path) {
    import std.file : append;
    JSONValue j;
    j["cell"] = cell["id"].str;
    j["baseOurs"] = run.baseOurs;
    if (run.layer != [1L, 1L]) j["layer"] = JSONValue(run.layer[]);
    JSONValue[] pts;
    foreach (o; run.obs) {
        JSONValue q;
        q["label"] = o.label; q["image"] = o.image; q["vcount"] = o.vcount;
        q["armed"] = o.armed; q["on"] = o.on;
        q["attrs"] = o.attrs is null ? JSONValue(null) : JSONValue(o.attrs);
        q["origin"] = o.origin;
        q["undoRows"] = o.undoRows; q["redoRows"] = o.redoRows; q["redoSteps"] = o.redoSteps;
        pts ~= q;
    }
    j["points"] = pts;
    append(path, j.toString ~ "\n");
}

/// Cells this process played and compared (the suite's last block checks the count).
size_t cellsCompared;

/// One cell of a family suite: play, check the rig, then compare (or dump).
void runCell(const JSONValue fixture, string id) {
    JSONValue cell;
    foreach (c; fixture["cells"].array) if (c["id"].str == id) cell = c;
    assert(cell.type == JSONType.object, "fixture holds no cell " ~ id);
    // VIBE3D_CELL=<id> runs one cell (a mutation's named witness, run in isolation)
    const only = environment.get("VIBE3D_CELL", "");
    if (only.length && only != id) return;
    auto run = playCell(cell);
    checkRig(cell, run, dormantHaulDemand(fixture, id));
    const dump = environment.get("VIBE3D_TOPO_REDO_DUMP", "");
    if (dump.length) { dumpCell(cell, run, dump); return; }
    compareCell(cell, run);
    ++cellsCompared;
    cmdOk("/api/command", "tool.set " ~ rigOf(cell["variant"].str).tool ~ " off", "cell " ~ id);
}

/// The fixture's own structure (plan §4.7 R8 rule 1): a known divergence whose declared
/// value IS the reference exists only for a point that got its owner from a classmate
/// (`classOwned`), and `classOwned` is exactly the set of (point, source, owner) triples
/// the fixture's `image` fields imply. Returns the triples it found (for the floor).
string[] classOwnedTriples(const JSONValue fixture) {
    string[] got;
    foreach (c; fixture["cells"].array) {
        if (!c["measured"].boolean) continue;
        JSONValue[string] img;
        foreach (p; c["points"].array)
            if (auto f = "image" in p["fields"]) img[p["label"].str] = *f;
        foreach (p; c["points"].array) {
            foreach (field, f; p["fields"].object) {
                if ("ours" !in f || "ref" !in f) continue;
                const self = f["ours"].toString == f["ref"].toString;
                const at = c["id"].str ~ "/" ~ p["label"].str;
                if (!self || field != "image") continue;   // other fields: compareCell
                bool any;
                foreach (s; f["ref"].array)
                    foreach (lab, g; img)
                        if (lab.length > 3 && lab[0 .. 3] == s.str && "ours" in g) {
                            got ~= at ~ " <- " ~ c["id"].str ~ "/" ~ lab ~ " (" ~ g["owner"].str ~ ")";
                            any = true;
                        }
                assert(any, "fixture: " ~ at ~ ".image declares ours == reference with no "
                    ~ "known-divergence classmate (class rule, plan §4.7 R8)");
            }
        }
    }
    string[] want;
    foreach (t; fixture["classOwned"].array)
        want ~= t["point"].str ~ " <- " ~ t["source"].str ~ " (" ~ t["owner"].str ~ ")";
    got.sort(); want.sort();
    assert(got == want, format("fixture classOwned %s differs from the triples its image fields imply %s",
        want, got));
    return got;
}

/// The frozen field `field` of `cell`/`label` — asserted present (a field the generator
/// dropped is a field no run judges).
JSONValue frozenField(const JSONValue fixture, string cell, string label, string field) {
    foreach (c; fixture["cells"].array) {
        if (c["id"].str != cell) continue;
        foreach (p; c["points"].array)
            if (p["label"].str == label) {
                auto f = field in p["fields"].object;
                assert(f !is null, format("fixture: %s/%s freezes no %s (not judged)", cell,
                    label, field));
                return *f;
            }
        assert(false, format("fixture: %s has no checkpoint %s", cell, label));
    }
    assert(false, "fixture holds no cell " ~ cell);
}

/// A reference class relation (an array of checkpoint names) holds `name`.
bool classHas(const JSONValue f, string name) {
    return f["ref"].array.canFind!(v => v.str == name);
}

/// The ladder of a headless apply after a scripted write (capture 8960, findings §16.3),
/// as the fixture freezes it for `cell` (s03 the write, s04 the apply, s05 Z1, s06 Z2):
/// the apply stacks a new image; Z1 takes the apply ALONE (the write's image, the write's
/// attributes, tool active, not armed); Z2 reopens post mode with the haul's attributes.
/// Every field named here is judged (present), whatever its status.
void pinApplyLadder(const JSONValue fx, string cell) {
    const ctx = "8960 " ~ cell;
    assert(frozenField(fx, cell, "s04_cmd", "image")["ref"].array.length == 0,
        ctx ~ ": the apply's image is not new in the fixture");
    assert(frozenField(fx, cell, "s04_cmd", "armed")["ref"].type == JSONType.false_,
        ctx ~ ": the fixture's apply leaves the tool armed");
    auto z1 = frozenField(fx, cell, "s05_Z", "image");
    assert(classHas(z1, "s03") && !classHas(z1, "s04"), ctx ~ ": Z1 is not the write's image "
        ~ "in the fixture: " ~ z1["ref"].toString);
    assert(frozenField(fx, cell, "s05_Z", "armed")["ref"].type == JSONType.false_
        && frozenField(fx, cell, "s05_Z", "on")["ref"].str == "tool",
        ctx ~ ": Z1 is not 'tool active, not armed' in the fixture");
    assert(classHas(frozenField(fx, cell, "s05_Z", "attrs"), "s03"),
        ctx ~ ": Z1's attributes are not the write's in the fixture");
    assert(frozenField(fx, cell, "s06_Z", "armed")["ref"].type == JSONType.true_,
        ctx ~ ": Z2 does not reopen post mode in the fixture");
    auto a2 = frozenField(fx, cell, "s06_Z", "attrs");
    assert(classHas(a2, "s02") && !classHas(a2, "s03"), ctx ~ ": Z2's attributes are not the "
        ~ "haul's in the fixture: " ~ a2["ref"].toString);
    foreach (lab; ["s04_cmd", "s05_Z", "s06_Z"])
        foreach (fl; ["image", "vcount", "armed", "on", "attrs"])
            frozenField(fx, cell, lab, fl);
}

/// The family census line and its population floor (п.4: the message is about the
/// AREA — what the fixture holds for the family — not about what was looked for).
void familyFloor(const JSONValue fixture, string family, const string[] ids,
                 long cells, long checkpoints) {
    import std.stdio : writefln;
    string[] got;
    long pts, parity, divergence;
    foreach (c; fixture["cells"].array) {
        if (c["family"].str != family) continue;
        got ~= c["id"].str;
        foreach (p; c["points"].array) {
            ++pts;
            foreach (field, f; p["fields"].object)
                if ("ours" in f) ++divergence; else ++parity;
        }
    }
    writefln("TOPO-REDO-CELLS family=%s cells=%d checkpoints=%d parity=%d divergence=%d",
        family, got.length, pts, parity, divergence);
    assert(got.length == cells && pts == checkpoints,
        format("fixture family %s holds %d cells / %d checkpoints, the suite was frozen at %d / %d",
            family, got.length, pts, cells, checkpoints));
    auto a = got.dup; a.sort();
    auto b = ids.dup; b.sort();
    assert(a == b, format("fixture family %s cells %s differ from the suite's list %s",
        family, a, b));
}
