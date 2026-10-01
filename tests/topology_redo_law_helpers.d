module topology_redo_law_helpers;

// The executor and the comparison behind the topology-redo law suites (wave plan
// S1a; fixture `tests/fixtures/topology_redo_law_cells.json`, frozen by the private
// generator `freeze_fixture.py` from the reference captures). One step vocabulary,
// one observation, one comparison for every tool of the topology model — a tool
// differs from another only by its rig (`rigOf`). There is NO branch on a law here.
//
// A cell is a scenario (arm, hauls, navigation keys, attribute writes, commands) and
// a list of checkpoints. At each checkpoint the suite reads OUR product and reduces
// it to the same relations the generator reduced the reference to:
//   image   the EARLIER checkpoints with the same mesh + selection ([] = new)
//   vcount  vertex count, in the reference rig's numbers (ours − our base + its base)
//   armed   the session's post-mode flag;  on  "tool" | "move" | ""
//   refused a navigation key that moved no history row (Z/R checkpoints only)
//   attrs   the EARLIER checkpoints with the same tool attributes (tool on only)
//   origin  how a haul's step began — not written by the product yet: "absent"
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
    bool handle;        // press on handle part 0 (else the viewport centre)
    int[2] pressRef;    // the reference press the variant's g1 uses (offsets are relative)
    string[string] attrName;   // logical fixture attribute → our attribute
    JSONValue mesh;            // rig override (null: the reference rig as frozen)
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
    // the autoact and generator families are rigged by slice S1b
    case "edge_bevel": case "edge_extrude": case "vertex_bevel": case "vertex_extrude":
    case "mirror": case "mirror_wide": case "radial_array": case "array": case "clone":
        assert(false, "rig of variant " ~ variant ~ " belongs to the S1b suites");
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
    cmdOk("/api/command", commandBody("mesh.select",
        format(`{"mode":"%s","indices":%s}`, m["mode"].str, m["selected"].toString)), ctx);
    // an oblique view on the rig's centre: every handle off-axis, the whole rig in frame
    double[3] c = 0;
    foreach (v; m["vertices"].array)
        foreach (k; 0 .. 3) c[k] += num(v[k]) / m["vertices"].array.length;
    cmdOk("/api/camera", format(`{"azimuth":0.5,"elevation":0.4,"distance":7,`
        ~ `"focus":{"x":%.6f,"y":%.6f,"z":%.6f}}`, c[0], c[1], c[2]), ctx);
    cmdOk("/api/command", "history.clear", ctx);
    settle();
    return cast(long) getJson("/api/model")["vertices"].array.length;
}

private void pressPoint(const Rig rig, const JSONValue step, out int x, out int y) {
    auto cam = getJson("/api/camera");
    double bx = cam["vpX"].integer + cam["width"].integer / 2;
    double by = cam["vpY"].integer + cam["height"].integer / 2;
    if (rig.handle) {
        auto h = getJson("/api/tool/handles")["handles"];
        assert(h.type == JSONType.object, "rig: " ~ rig.tool ~ " shows no handle to haul");
        bool found;
        foreach (p; h["parts"].array)
            if (p["part"].integer == 0 && p["screen"].type == JSONType.array) {
                bx = num(p["screen"][0]); by = num(p["screen"][1]); found = true;
            }
        assert(found, "rig: " ~ rig.tool ~ " handle part 0 is not on screen");
    }
    x = cast(int)(bx + num(step["press"][0]) - rig.pressRef[0]);
    y = cast(int)(by + num(step["press"][1]) - rig.pressRef[1]);
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
        int x, y;
        pressPoint(rig, step, x, y);
        const dx = num(step["delta"][0]), dy = num(step["delta"][1]);
        drag(x, y, cast(int) dx, cast(int) dy, step["button"].str == "middle" ? 2 : 1);
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
        const line = format("tool.attr %s %s %.9g", rig.tool, rig.attrName[name], num(step["value"]));
        // plan §4.7 R4 lexicon: the panel = an interactive script write; the script door
        // = /api/command. `?origin=ui tool.attr` is NOT used (a scripted value, §4.7 R6).
        if (step["door"].str == "panel") cmdOk("/api/script?interactive=true", line, ctx);
        else cmdOk("/api/command", line, ctx);
        settle();
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
    case "rclick": {
        // an empty background point of the rig: the viewport's top-left corner region
        auto cam = getJson("/api/camera");
        tap(cast(int) cam["vpX"].integer + 24, cast(int) cam["vpY"].integer + 24, 3);
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
            parts ~= format("%s=%.6g", a, num(r["value"]));
        }
        o.attrs = parts.join(";");
    }
    auto h = getJson("/api/history");
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
                   const Obs* before) {
    switch (field) {
    case "image": return classOf(obs, i, (const Obs o) => o.image);
    case "vcount": return JSONValue(obs[i].vcount - baseOurs + baseRef);
    case "armed": return JSONValue(obs[i].armed);
    case "on": return JSONValue(obs[i].on);
    case "attrs":
        if (obs[i].attrs is null) return JSONValue("unreadable");
        return classOf(obs, i, (const Obs o) => o.attrs);
    case "refused":
        assert(before !is null);
        return JSONValue(before.undoRows == obs[i].undoRows && before.redoRows == obs[i].redoRows);
    case "origin": return JSONValue("absent");   // no step origin is written yet (S2b)
    case "redoRows": return JSONValue(obs[i].redoSteps);
    default: assert(false, "unknown field " ~ field);
    }
}

// ------------------------------------------------------------------ one cell

struct CellRun {
    Obs[] obs;            // one per checkpoint, s00 first
    long baseOurs;
}

/// Play the whole cell and observe every checkpoint.
CellRun playCell(const JSONValue cell) {
    const rig = rigOf(cell["variant"].str);
    CellRun run;
    run.baseOurs = setupCell(cell, rig);
    run.obs ~= observe("s00_prearm", rig);
    foreach (step; cell["steps"].array) {
        const label = step["label"].str;
        runStep(step, rig, "cell " ~ cell["id"].str ~ "/" ~ label);
        if (step["op"].str == "skip") continue;
        run.obs ~= observe(label, rig);
    }
    return run;
}

/// Rig preconditions (plan §5 S1a п.4): a run that fails one is VOID, not a verdict.
void checkRig(const JSONValue cell, const CellRun run) {
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
    if (canFind(id, "_dormant") && !starts("dormant")) {
        const k = at(hauls[$ - 1]);
        assert(run.obs[k].attrs != run.obs[k - 1].attrs,
            "rig: dormant haul changed no attribute in " ~ id);
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
    foreach (i, p; cell["points"].array) {
        const lab = p["label"].str;
        assert(lab == run.obs[i].label, "cell " ~ id ~ ": checkpoint order " ~ lab);
        foreach (field, f; p["fields"].object) {
            const ours = ourField(field, run.obs, i, run.baseOurs, baseRef,
                i ? &run.obs[i - 1] : null);
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
    JSONValue[] pts;
    foreach (o; run.obs) {
        JSONValue q;
        q["label"] = o.label; q["image"] = o.image; q["vcount"] = o.vcount;
        q["armed"] = o.armed; q["on"] = o.on;
        q["attrs"] = o.attrs is null ? JSONValue(null) : JSONValue(o.attrs);
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
    checkRig(cell, run);
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
