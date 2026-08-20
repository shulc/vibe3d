// Edge Extend — handle banks and the R/S pivot, against the frozen fixture
// `tests/fixtures/edge_extend/handles_and_pivot.json` (task 1610).
//
// This is the ARMED-TOOL half of the fixture. Its sibling,
// `tests/unit/tools/edit/edge_extend_pivot_test.d`, reads the same file and
// pins the pivot as a POINT (bbox mid, not centroid) through the kernel with
// no app in sight. What only a live tool can show is the other two things:
//
//   * WHICH BANKS ARE OFFERED. Move is on and rotate/scale are off by default.
//     We used to hard-wire all three on, so a user could grab a rotate ring
//     and get a translate — the drag was never wired. The fix is the switch,
//     not two new handlers.
//   * WHEN THE PIVOT IS TAKEN. At tool INITIALISATION. The pivot is already
//     populated the moment the tool is armed, before any drag and before any
//     parameter is written, and it does not move afterwards. Freezing it at
//     drag start instead — which is what this code used to do — leaves it at
//     the origin here, and cell 2 goes red by 3.87.
//   * THAT THE ACTION CENTRE IS NOT IN IT. Cell 3 forces the action centre to
//     the world origin and the pivot does not move. The old code read
//     `xfrm.actionCenter(vts)`, so that cell would have reported (0,0,0).
//
// The rig is the fixture's own and must not be simplified: an open 5-vertex /
// 2-triangle mesh off the origin, nothing axis-aligned, two selected edges
// sharing a vertex with a ~13x length ratio (this separates the box mid from
// the centroid), two unselected vertices outside the selection (this separates
// the selected subset's box from the whole mesh's), and a COMPOSITE rotation
// (a single-axis one leaves the pivot's third coordinate unrecoverable).
//
// DO NOT ADD A CUBE CELL HERE. On a cube edge the box mid, the centroid and
// the select-mode action centre are the same point, so every candidate law
// passes and the cell proves nothing. The unit-test sibling asserts that
// coincidence outright rather than leaving it as advice.

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : sqrt, abs;

void main() {}

// --- fixture ---------------------------------------------------------------

enum string kFixtureText = import("fixtures/edge_extend/handles_and_pivot.json");

JSONValue fixture() {
    static JSONValue cached;
    static bool loaded = false;
    if (!loaded) {
        cached = parseJSON(kFixtureText);
        assert(cached["fixture"].str == "edge_extend_handles_and_pivot",
            "wrong fixture embedded");
        loaded = true;
    }
    return cached;
}

// --- HTTP helpers (same shapes as tests/test_edge_extend_tool.d) ------------

void cmd(string s) {
    auto resp = post("http://localhost:8080/api/command", s);
    assert(parseJSON(resp)["status"].str == "ok", "cmd `" ~ s ~ "` failed: " ~ resp);
}

void resetCube() {
    auto resp = post("http://localhost:8080/api/reset?type=cube", "");
    assert(parseJSON(resp)["status"].str == "ok", "/api/reset cube failed: " ~ resp);
}

JSONValue getModel() { return parseJSON(cast(string)get("http://localhost:8080/api/model")); }
JSONValue toolState() { return parseJSON(cast(string)get("http://localhost:8080/api/tool/state")); }

void postSelect(string mode, int[] indices) {
    string idxJson = "[";
    foreach (i, v; indices) { if (i > 0) idxJson ~= ","; idxJson ~= v.to!string; }
    idxJson ~= "]";
    auto resp = post("http://localhost:8080/api/select",
        `{"mode":"` ~ mode ~ `","indices":` ~ idxJson ~ `}`);
    assert(parseJSON(resp)["status"].str == "ok", "/api/select failed: " ~ resp);
}

// Arm the hidden one-shot pivot override for the NEXT doApply. Cell 4 feeds it
// the pivot it just READ BACK from the armed tool, so the chain stays closed:
// a tool that computed the wrong point would drive the kernel about the wrong
// point and the golden ring would not reproduce.
void setDragPivot(double[3] p) {
    auto body = `{"id":"tool.attr","params":{"_positional":["edge.extend","_dragPivot",`
        ~ `[` ~ p[0].to!string ~ `,` ~ p[1].to!string ~ `,` ~ p[2].to!string ~ `]]}}`;
    auto resp = post("http://localhost:8080/api/command", body);
    assert(parseJSON(resp)["status"].str == "ok", "_dragPivot set failed: " ~ resp);
}

// --- rig -------------------------------------------------------------------

struct V3 { double x, y, z; }

V3 v3(JSONValue a) {
    double num(JSONValue x) {
        return x.type == JSONType.integer ? cast(double)x.integer : x.floating;
    }
    return V3(num(a.array[0]), num(a.array[1]), num(a.array[2]));
}

double dist(V3 a, V3 b) {
    double dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z;
    return sqrt(dx*dx + dy*dy + dz*dz);
}

string vecStr(V3 p) {
    return "(" ~ p.x.to!string ~ "," ~ p.y.to!string ~ "," ~ p.z.to!string ~ ")";
}

// Tolerance: same derivation as the unit sibling — the fixture prints six
// decimals, the kernel is float32 at coordinates of order 5, so the floor is
// ~2e-6. 1e-4 clears it and is still far below the 0.29 by which the nearest
// rival pivot displaces the ring.
enum double kTol = 1e-4;

// Load the fixture's rig and select its two edges (edge mode).
void loadRig() {
    auto rig = fixture()["rig"];
    string verts = "[";
    foreach (i, v; rig["vertices"].array) {
        auto p = v3(v);
        if (i > 0) verts ~= ",";
        verts ~= "[" ~ p.x.to!string ~ "," ~ p.y.to!string ~ "," ~ p.z.to!string ~ "]";
    }
    verts ~= "]";
    string faces = "[";
    foreach (i, f; rig["faces"].array) {
        if (i > 0) faces ~= ",";
        faces ~= "[";
        foreach (j, x; f.array) {
            if (j > 0) faces ~= ",";
            faces ~= x.integer.to!string;
        }
        faces ~= "]";
    }
    faces ~= "]";
    auto resp = post("http://localhost:8080/api/load-mesh",
        `{"vertices":` ~ verts ~ `,"faces":` ~ faces ~ `}`);
    assert(parseJSON(resp)["status"].str == "ok", "/api/load-mesh rig failed: " ~ resp);

    auto m = getModel();
    int[] sel;
    foreach (pair; rig["selected_edges"].array) {
        long a = pair.array[0].integer, b = pair.array[1].integer;
        int found = -1;
        foreach (i, e; m["edges"].array) {
            long x = e.array[0].integer, y = e.array[1].integer;
            if ((x == a && y == b) || (x == b && y == a)) { found = cast(int)i; break; }
        }
        assert(found >= 0, "rig edge (" ~ a.to!string ~ "," ~ b.to!string ~ ") missing");
        sel ~= found;
    }
    postSelect("edges", sel);
}

V3 statePivot() {
    auto st = toolState();
    assert(st["tool"].str == "edgeExtend", "not the edge-extend tool: " ~ st.toString);
    return v3(st["pivot"]);
}

// The ring the kernel appended: the tail of the vertex array, one vertex per
// distinct selected vertex, in source order (the kernel is pure-add, so the
// original five are untouched — asserted in cell 4).
V3[] ringVerts(JSONValue m, size_t sourceCount) {
    V3[] out_;
    foreach (i; sourceCount .. m["vertices"].array.length)
        out_ ~= v3(m["vertices"].array[i]);
    return out_;
}

// ---------------------------------------------------------------------------
// 1. BANK DEFAULTS. Move on, rotate and scale off — read from the fixture's
//    own `parameter_defaults` table, not from a copy of it here.
//
//    Before this task all three were hard-wired on, so this cell fails on the
//    old code with `rotateHandle` true.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    auto m = getModel();
    // Any edge will do — this cell is about the tool's defaults, not geometry.
    postSelect("edges", [0]);
    cmd("tool.set edge.extend on");

    auto st = toolState();
    auto defs = fixture()["parameter_defaults"];
    auto banks = fixture()["handle_banks"];

    // The fixture must agree with itself first: the bank table and the
    // defaults table are two records of the same switch, and a fixture edit
    // that desynchronised them would quietly weaken everything below.
    foreach (name; ["move", "rotate", "scale"]) {
        bool onInBankTable = banks[name]["default_on"].type == JSONType.true_;
        bool onInDefaults  = defs[name ~ "Handle"].type == JSONType.true_;
        assert(onInBankTable == onInDefaults,
            "fixture disagrees with itself about the " ~ name ~ " bank");
    }

    foreach (name; ["moveHandle", "rotateHandle", "scaleHandle"]) {
        bool want = defs[name].type == JSONType.true_;
        bool got  = st[name].type == JSONType.true_;
        assert(got == want,
            name ~ ": expected " ~ (want ? "on" : "off") ~ ", got "
            ~ (got ? "on" : "off") ~ " — we must not draw a bank that is not "
            ~ "offered there, least of all one whose drag is unwired");
    }
    assert(st["moveHandle"].type == JSONType.true_,
        "exactly one bank is on by default and it is MOVE");

    // The `inset` default moved 0.1 -> 0.0 in the same task; same table.
    double wantInset = defs["inset"].type == JSONType.integer
                     ? cast(double)defs["inset"].integer : defs["inset"].floating;
    assert(abs(st["inset"].floating - wantInset) < 1e-9,
        "inset default: expected " ~ wantInset.to!string ~ ", got "
        ~ st["inset"].floating.to!string);

    // The plane bank, the local bank and the local haul mode are NOT
    // implemented. They are default-OFF in the fixture too, so their absence
    // is a gap and not a divergence — but assert the fixture still says so,
    // or this paragraph silently becomes a lie.
    assert(banks["plane"]["default_on"].type == JSONType.false_
        && banks["local"]["default_on"].type == JSONType.false_
        && defs["haul"].str == "global",
        "an unimplemented bank became default-ON in the fixture — it is now a "
        ~ "divergence, not a gap, and needs its own task");

    cmd("tool.set edge.extend off");
}

// ---------------------------------------------------------------------------
// 2. THE PIVOT, POINT AND MOMENT. On the discriminating rig, arming the tool
//    is enough: the pivot is the bbox mid of the selected vertices and it is
//    already there, with no drag and no parameter written.
//
//    MUTATION (freeze at drag start, i.e. the old code): nothing populates the
//    pivot at arm time, so this reads (0,0,0) and the cell fails by 3.87.
//    MUTATION (centroid instead of box mid): fails by 0.77.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    loadRig();
    cmd("tool.set edge.extend on");

    V3 pivot = statePivot();
    auto cands = fixture()["pivot_candidates"];
    V3 want = v3(cands["bbox_mid_of_selected_vertices"]);

    assert(dist(pivot, want) < kTol,
        "armed-tool pivot is " ~ vecStr(pivot) ~ ", expected the selection's "
        ~ "bbox mid " ~ vecStr(want) ~ " (off by "
        ~ dist(pivot, want).to!string ~ ")");

    // ... and it is none of the three rivals. Spelling them out is what makes
    // the cell above evidence rather than a coincidence.
    foreach (name; ["centroid_of_selected_vertices",
                    "bbox_mid_of_whole_mesh",
                    "world_origin"]) {
        V3 rival = v3(cands[name]);
        assert(dist(pivot, rival) > 0.1,
            "armed-tool pivot cannot be told apart from `" ~ name ~ "`");
    }

    // The MOMENT: a parameter write does not move it, and neither does the
    // apply. Recomputing per evaluation is the other candidate law and this is
    // what refuses it.
    cmd("tool.attr edge.extend rotateZ 40");
    assert(dist(statePivot(), want) < kTol, "a parameter write moved the pivot");
    cmd("tool.doApply");
    assert(dist(statePivot(), want) < kTol, "the apply moved the pivot");

    cmd("tool.set edge.extend off");
}

// ---------------------------------------------------------------------------
// 3. THE ACTION-CENTRE CONTROL — the fixture's `action_centre_control`,
//    reproduced on our side. Forcing the action centre to the world origin
//    must leave the pivot exactly where it was.
//
//    This is the cell that refuses the code we shipped until today, which read
//    `xfrm.actionCenter(vts)`: under `actr.origin` it would report (0,0,0).
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    loadRig();

    cmd("tool.set edge.extend on");
    V3 before = statePivot();
    cmd("tool.set edge.extend off");

    cmd("actr.origin");            // action centre pinned to the world origin
    cmd("tool.set edge.extend on");
    V3 after = statePivot();
    cmd("tool.set edge.extend off");
    cmd("actr.auto");              // restore, so later cells start from default

    assert(dist(after, before) < kTol,
        "the action centre moved the extend pivot (" ~ vecStr(before) ~ " -> "
        ~ vecStr(after) ~ "); it must play no part in it");
    assert(dist(after, v3(fixture()["pivot_candidates"]["world_origin"])) > 0.1,
        "the pivot followed the action centre to the origin");
}

// ---------------------------------------------------------------------------
// 4. THE GEOMETRY, interactive case. Drive the kernel about the pivot READ
//    BACK from the armed tool and the frozen ring reproduces. Closed chain:
//    the tool computes the point, the test only carries it.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    loadRig();
    auto rigVerts = fixture()["rig"]["vertices"].array;
    size_t sourceCount = rigVerts.length;

    cmd("tool.set edge.extend on");
    V3 pivot = statePivot();
    setDragPivot([pivot.x, pivot.y, pivot.z]);

    auto c = fixture()["cases"].array[0];
    assert(c["name"].str == "interactive_rotate_pivot");
    auto p = c["parameters"];
    cmd("tool.attr edge.extend rotateX " ~ p["rotateX_deg"].floating.to!string);
    cmd("tool.attr edge.extend rotateZ " ~ p["rotateZ_deg"].floating.to!string);
    cmd("tool.doApply");

    auto m = getModel();
    auto topo = fixture()["topology_after_one_application"];
    assert(m["vertexCount"].integer == topo["vertex_count"].integer,
        "vertex count: got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == topo["face_count"].integer,
        "face count: got " ~ m["faceCount"].integer.to!string);

    // Pure-add: the source cage is untouched.
    foreach (i; 0 .. sourceCount)
        assert(dist(v3(m["vertices"].array[i]), v3(rigVerts[i])) < kTol,
            "source vertex " ~ i.to!string ~ " moved");

    auto gold = c["new_ring_vertices"].array;
    auto ring = ringVerts(m, sourceCount);
    assert(ring.length == gold.length,
        "expected " ~ gold.length.to!string ~ " new vertices, got "
        ~ ring.length.to!string);
    foreach (i, g; gold)
        assert(dist(ring[i], v3(g)) < kTol,
            "ring vertex " ~ i.to!string ~ " is " ~ dist(ring[i], v3(g)).to!string
            ~ " off the frozen value: got " ~ vecStr(ring[i]) ~ ", want "
            ~ vecStr(v3(g)));

    cmd("tool.set edge.extend off");
}

// ---------------------------------------------------------------------------
// 5. THE GEOMETRY, command case — the fixture's own CONTROL. Same tool, same
//    parameters, same rig, no pivot: the non-interactive path pivots at the
//    world origin, there as here.
//
//    It is what makes cell 4 evidence. The two cells differ only in the pivot
//    and their outputs are 1.9 apart, so cell 4 cannot pass on a stale or
//    absent pivot.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    loadRig();
    size_t sourceCount = fixture()["rig"]["vertices"].array.length;

    cmd("tool.set edge.extend on");
    auto c = fixture()["cases"].array[1];
    assert(c["name"].str == "command_path_rotate_pivot");
    assert(c["matched_candidate"].str == "world_origin");
    auto p = c["parameters"];
    cmd("tool.attr edge.extend rotateX " ~ p["rotateX_deg"].floating.to!string);
    cmd("tool.attr edge.extend rotateZ " ~ p["rotateZ_deg"].floating.to!string);
    cmd("tool.doApply");           // no _dragPivot armed -> world origin

    auto m = getModel();
    auto gold = c["new_ring_vertices"].array;
    auto ring = ringVerts(m, sourceCount);
    foreach (i, g; gold)
        assert(dist(ring[i], v3(g)) < kTol,
            "command-path ring vertex " ~ i.to!string ~ " is "
            ~ dist(ring[i], v3(g)).to!string ~ " off the frozen value");

    // The two paths really do part company.
    auto interactiveGold = fixture()["cases"].array[0]["new_ring_vertices"].array;
    double worst = 0;
    foreach (i, g; gold) {
        double d = dist(v3(g), v3(interactiveGold[i]));
        if (d > worst) worst = d;
    }
    assert(worst > 1.0,
        "the two pivot paths must produce visibly different geometry; worst "
        ~ "separation is only " ~ worst.to!string);

    cmd("tool.set edge.extend off");
}
