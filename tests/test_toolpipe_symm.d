// Tests for phase 7.6a: SymmetryStage skeleton + master toggle.
//
// Verifies:
// - SYMM stage is registered at TaskCode.Symm, ordinal 0x31.
// - Default attrs: enabled=false, axis=x, offset=0, useWorkplane=false,
//   topology=false, epsilon=1e-4.
// - tool.pipe.attr symmetry <name> <value> round-trips through listAttrs.
// - Bogus values are rejected (setAttr fails — listAttrs still shows
//   the previous value).

import std.net.curl;
import std.json;
import std.conv : to;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string) get(baseUrl ~ path));
}

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(baseUrl ~ path, body_));
}

string[string] getSymmetryAttrs() {
    auto j = getJson("/api/toolpipe");
    foreach (st; j["stages"].array) {
        if (st["task"].str == "SYMM") {
            string[string] out_;
            foreach (k, v; st["attrs"].object) out_[k] = v.str;
            return out_;
        }
    }
    assert(false, "SYMM stage missing from /api/toolpipe");
}

void resetCube() {
    postJson("/api/reset", `{"primitive":"cube"}`);
    postJson("/api/command", "tool.pipe.attr symmetry enabled false");
    postJson("/api/command", "tool.pipe.attr symmetry axis x");
    postJson("/api/command", "tool.pipe.attr symmetry offset 0");
    postJson("/api/command", "tool.pipe.attr symmetry useWorkplane false");
    postJson("/api/command", "tool.pipe.attr symmetry topology false");
    postJson("/api/command", "tool.pipe.attr symmetry epsilon 0.0001");
}

// -------------------------------------------------------------------------
// 7.6a: SYMM stage is registered with correct task / id / ordinal.
// -------------------------------------------------------------------------

unittest { // SYMM stage present
    resetCube();
    auto j = getJson("/api/toolpipe");
    bool found = false;
    foreach (st; j["stages"].array) {
        if (st["task"].str != "SYMM") continue;
        assert(st["id"].str == "symmetry",
            "SYMM stage id should be 'symmetry', got " ~ st["id"].str);
        assert(st["ordinal"].integer == 0x31,
            "SYMM ordinal should be 0x31, got "
            ~ st["ordinal"].integer.to!string);
        assert(st["enabled"].type == JSONType.true_,
            "SymmetryStage should be enabled (registered) by default");
        found = true;
    }
    assert(found, "SYMM stage missing from /api/toolpipe");
}

// -------------------------------------------------------------------------
// 7.6a: defaults.
// -------------------------------------------------------------------------

unittest { // defaults
    resetCube();
    auto a = getSymmetryAttrs();
    assert(a["enabled"]      == "false",  "default enabled: " ~ a["enabled"]);
    assert(a["axis"]         == "x",      "default axis: "    ~ a["axis"]);
    assert(a["offset"]       == "0",      "default offset: "  ~ a["offset"]);
    assert(a["useWorkplane"] == "false",  "default useWorkplane: " ~ a["useWorkplane"]);
    assert(a["topology"]     == "false",  "default topology: " ~ a["topology"]);
    assert(a["epsilon"]      == "0.0001", "default epsilon: " ~ a["epsilon"]);
}

// -------------------------------------------------------------------------
// 7.6a: enabled / useWorkplane / topology bool round-trip.
// -------------------------------------------------------------------------

unittest { // enabled toggle
    resetCube();
    postJson("/api/command", "tool.pipe.attr symmetry enabled true");
    assert(getSymmetryAttrs()["enabled"] == "true");
    postJson("/api/command", "tool.pipe.attr symmetry enabled false");
    assert(getSymmetryAttrs()["enabled"] == "false");
}

unittest { // useWorkplane toggle
    resetCube();
    postJson("/api/command", "tool.pipe.attr symmetry useWorkplane true");
    assert(getSymmetryAttrs()["useWorkplane"] == "true");
    postJson("/api/command", "tool.pipe.attr symmetry useWorkplane false");
    assert(getSymmetryAttrs()["useWorkplane"] == "false");
}

unittest { // topology toggle (schema-only in v1; round-trips like any bool)
    resetCube();
    postJson("/api/command", "tool.pipe.attr symmetry topology true");
    assert(getSymmetryAttrs()["topology"] == "true");
    postJson("/api/command", "tool.pipe.attr symmetry topology false");
    assert(getSymmetryAttrs()["topology"] == "false");
}

// -------------------------------------------------------------------------
// 7.6a: axis setAttr round-trip for each recognised value.
// -------------------------------------------------------------------------

unittest { // axis x / y / z
    resetCube();
    foreach (label; ["x", "y", "z"]) {
        postJson("/api/command", "tool.pipe.attr symmetry axis " ~ label);
        auto a = getSymmetryAttrs();
        assert(a["axis"] == label,
            "axis expected " ~ label ~ ", got " ~ a["axis"]);
    }
}

unittest { // axis uppercase also accepted
    resetCube();
    postJson("/api/command", "tool.pipe.attr symmetry axis Y");
    auto a = getSymmetryAttrs();
    assert(a["axis"] == "y",
        "uppercase 'Y' should map to lowercase 'y', got " ~ a["axis"]);
}

// -------------------------------------------------------------------------
// 7.6a: scalar attrs round-trip.
// -------------------------------------------------------------------------

unittest { // offset float
    resetCube();
    postJson("/api/command", "tool.pipe.attr symmetry offset 2.5");
    auto a = getSymmetryAttrs();
    assert(a["offset"] == "2.5", "offset: " ~ a["offset"]);
}

unittest { // epsilon float
    resetCube();
    postJson("/api/command", "tool.pipe.attr symmetry epsilon 0.001");
    auto a = getSymmetryAttrs();
    assert(a["epsilon"] == "0.001", "epsilon: " ~ a["epsilon"]);
}

// -------------------------------------------------------------------------
// 7.6a: bogus values must not corrupt state.
// -------------------------------------------------------------------------

unittest { // bogus axis rejected
    resetCube();
    postJson("/api/command", "tool.pipe.attr symmetry axis y");
    cast(void)post(baseUrl ~ "/api/command",
                   "tool.pipe.attr symmetry axis bogus");
    auto a = getSymmetryAttrs();
    assert(a["axis"] == "y",
        "bogus axis must not change state; got " ~ a["axis"]);
}

unittest { // negative epsilon rejected
    resetCube();
    postJson("/api/command", "tool.pipe.attr symmetry epsilon 0.001");
    cast(void)post(baseUrl ~ "/api/command",
                   "tool.pipe.attr symmetry epsilon -1");
    auto a = getSymmetryAttrs();
    assert(a["epsilon"] == "0.001",
        "negative epsilon must be rejected; got " ~ a["epsilon"]);
}

unittest { // unknown attr rejected
    resetCube();
    auto r = postJson("/api/command", "tool.pipe.attr symmetry nosuchattr 1");
    assert(r["status"].str != "ok",
        "unknown attr should fail, got " ~ r.toString);
}

// -------------------------------------------------------------------------
// 7.6b: pair table — default cube (8 verts) → 4 X-symmetric pairs when
// the X-plane is active. Layout from test_transform.d:
//   v0=(-,-,-)  v1=(+,-,-)  v2=(+,+,-)  v3=(-,+,-)
//   v4=(-,-,+)  v5=(+,-,+)  v6=(+,+,+)  v7=(-,+,+)
// Mirror across X=0: (0↔1), (2↔3), (4↔5), (6↔7).
// -------------------------------------------------------------------------

unittest { // pairOf cube X
    resetCube();
    postJson("/api/command", "tool.pipe.attr symmetry enabled true");
    postJson("/api/command", "tool.pipe.attr symmetry axis x");

    auto j = getJson("/api/toolpipe/eval");
    auto sym = j["symmetry"];
    assert(sym["enabled"].type == JSONType.true_, sym.toString);
    auto po = sym["pairOf"].array;
    assert(po.length == 8, "pairOf should be 8 long, got "
        ~ po.length.to!string);
    // Wait for the pair table to settle. The toolpipe eval rebuilds
    // pairing on first read with a freshly-enabled stage.
    int[8] expected = [1, 0, 3, 2, 5, 4, 7, 6];
    foreach (i; 0 .. 8) {
        assert(po[i].integer == expected[i],
            "pairOf[" ~ i.to!string ~ "] expected "
            ~ expected[i].to!string ~ ", got "
            ~ po[i].integer.to!string);
    }
    // None of the cube's 8 verts lie on X=0 (they sit at ±0.5).
    auto op = sym["onPlane"].array;
    foreach (i; 0 .. 8) {
        assert(op[i].type == JSONType.false_,
            "onPlane[" ~ i.to!string ~ "] expected false, got "
            ~ op[i].toString);
    }
}

unittest { // pairOf cube Y
    resetCube();
    postJson("/api/command", "tool.pipe.attr symmetry enabled true");
    postJson("/api/command", "tool.pipe.attr symmetry axis y");

    auto j = getJson("/api/toolpipe/eval");
    auto po = j["symmetry"]["pairOf"].array;
    // Y-mirror of cube layout (above):
    //   v0(-,-,-)↔v3(-,+,-)  v1(+,-,-)↔v2(+,+,-)
    //   v4(-,-,+)↔v7(-,+,+)  v5(+,-,+)↔v6(+,+,+)
    int[8] expected = [3, 2, 1, 0, 7, 6, 5, 4];
    foreach (i; 0 .. 8) {
        assert(po[i].integer == expected[i],
            "Y-pairOf[" ~ i.to!string ~ "] expected "
            ~ expected[i].to!string ~ ", got "
            ~ po[i].integer.to!string);
    }
}

unittest { // pairOf cube Z
    resetCube();
    postJson("/api/command", "tool.pipe.attr symmetry enabled true");
    postJson("/api/command", "tool.pipe.attr symmetry axis z");

    auto j = getJson("/api/toolpipe/eval");
    auto po = j["symmetry"]["pairOf"].array;
    // Z-mirror:
    //   v0(-,-,-)↔v4(-,-,+)  v1(+,-,-)↔v5(+,-,+)
    //   v2(+,+,-)↔v6(+,+,+)  v3(-,+,-)↔v7(-,+,+)
    int[8] expected = [4, 5, 6, 7, 0, 1, 2, 3];
    foreach (i; 0 .. 8) {
        assert(po[i].integer == expected[i],
            "Z-pairOf[" ~ i.to!string ~ "] expected "
            ~ expected[i].to!string ~ ", got "
            ~ po[i].integer.to!string);
    }
}

unittest { // pairOf empty when disabled
    resetCube();
    postJson("/api/command", "tool.pipe.attr symmetry enabled false");
    auto j = getJson("/api/toolpipe/eval");
    auto po = j["symmetry"]["pairOf"].array;
    assert(po.length == 0, "disabled stage should publish empty pair table");
}

// -------------------------------------------------------------------------
// 7.6b: vert.symmetrize-style move via /api/transform translate.
// MeshTransform consults the SYMM packet — selecting vert 0 and translating
// (0, 1, 0) should also translate vert 1 (its X-mirror).
// -------------------------------------------------------------------------

bool approxEq(double a, double b) {
    import std.math : fabs;
    return fabs(a - b) < 1e-4;
}

double[3] vertexAt(int idx) {
    auto m = parseJSON(cast(string) get(baseUrl ~ "/api/model"));
    auto v = m["vertices"].array[idx].array;
    return [v[0].floating, v[1].floating, v[2].floating];
}

unittest { // translate one corner with X-symm → mirror also moves
    postJson("/api/reset", "");
    postJson("/api/command", "tool.pipe.attr symmetry enabled true");
    postJson("/api/command", "tool.pipe.attr symmetry axis x");
    // Select vert 0 = (-0.5, -0.5, -0.5) only.
    postJson("/api/select", `{"mode":"vertices","indices":[0]}`);
    postJson("/api/transform",
        `{"kind":"translate","delta":[0,1,0]}`);

    auto v0 = vertexAt(0);
    auto v1 = vertexAt(1);
    assert(approxEq(v0[0], -0.5) && approxEq(v0[1], 0.5) && approxEq(v0[2], -0.5),
        "v0 should have moved to (-0.5,0.5,-0.5), got "
        ~ v0[0].to!string ~ "," ~ v0[1].to!string ~ "," ~ v0[2].to!string);
    assert(approxEq(v1[0], 0.5) && approxEq(v1[1], 0.5) && approxEq(v1[2], -0.5),
        "v1 (mirror) should have moved to (0.5,0.5,-0.5), got "
        ~ v1[0].to!string ~ "," ~ v1[1].to!string ~ "," ~ v1[2].to!string);
    // Other corners untouched.
    auto v2 = vertexAt(2);
    assert(approxEq(v2[0],  0.5) && approxEq(v2[1],  0.5) && approxEq(v2[2], -0.5),
        "v2 should be unchanged, got "
        ~ v2[0].to!string ~ "," ~ v2[1].to!string ~ "," ~ v2[2].to!string);

    postJson("/api/command", "tool.pipe.attr symmetry enabled false");
    postJson("/api/reset", "");
}

// -------------------------------------------------------------------------
// 7.6b: translating along the symmetry axis itself — both corners move
// AWAY from the plane symmetrically.
// -------------------------------------------------------------------------

unittest { // translate along the X axis with X-symm → mirror moves opposite
    postJson("/api/reset", "");
    postJson("/api/command", "tool.pipe.attr symmetry enabled true");
    postJson("/api/command", "tool.pipe.attr symmetry axis x");
    postJson("/api/select", `{"mode":"vertices","indices":[0]}`);
    postJson("/api/transform",
        `{"kind":"translate","delta":[-1,0,0]}`);
    auto v0 = vertexAt(0);
    auto v1 = vertexAt(1);
    // v0 moved from -0.5 to -1.5; mirror at -(-1.5) = 1.5
    assert(approxEq(v0[0], -1.5), "v0.x expected -1.5, got " ~ v0[0].to!string);
    assert(approxEq(v1[0],  1.5), "v1.x expected  1.5, got " ~ v1[0].to!string);
    postJson("/api/command", "tool.pipe.attr symmetry enabled false");
    postJson("/api/reset", "");
}

// -------------------------------------------------------------------------
// 7.6b: revert restores both the moved vert AND its mirror counterpart.
// MeshTransform extends touchedIdx with the mirror so /api/undo unwinds it.
// -------------------------------------------------------------------------

unittest { // undo restores mirror
    postJson("/api/reset", "");
    postJson("/api/command", "tool.pipe.attr symmetry enabled true");
    postJson("/api/command", "tool.pipe.attr symmetry axis x");
    postJson("/api/select", `{"mode":"vertices","indices":[0]}`);
    postJson("/api/transform",
        `{"kind":"translate","delta":[0,2,0]}`);
    // sanity
    auto preUndo = vertexAt(1);
    assert(approxEq(preUndo[1], 1.5), "pre-undo v1.y: " ~ preUndo[1].to!string);

    postJson("/api/undo", "");
    auto v0 = vertexAt(0);
    auto v1 = vertexAt(1);
    assert(approxEq(v0[1], -0.5) && approxEq(v1[1], -0.5),
        "undo should restore both v0 and v1 to y=-0.5, got "
        ~ v0[1].to!string ~ ", " ~ v1[1].to!string);
    postJson("/api/command", "tool.pipe.attr symmetry enabled false");
    postJson("/api/reset", "");
}

// -------------------------------------------------------------------------
// 7.6b: when a selected vertex lies ON the plane, the translate gets
// projected onto the plane (the perpendicular component is stripped).
// Setup: use offset to put the plane at X=-0.5, select vert 0 at
// (-0.5,-0.5,-0.5). Translate (1, 1, 1) → vert 0 should move by (0, 1, 1)
// because the X component (perpendicular to the plane) is projected out.
// -------------------------------------------------------------------------

unittest { // on-plane vertex projected
    postJson("/api/reset", "");
    postJson("/api/command", "tool.pipe.attr symmetry enabled true");
    postJson("/api/command", "tool.pipe.attr symmetry axis x");
    postJson("/api/command", "tool.pipe.attr symmetry offset -0.5");
    postJson("/api/select", `{"mode":"vertices","indices":[0]}`);
    postJson("/api/transform",
        `{"kind":"translate","delta":[1,1,1]}`);
    auto v0 = vertexAt(0);
    // X projected onto plane (perpendicular stripped) → stays at -0.5.
    assert(approxEq(v0[0], -0.5) && approxEq(v0[1], 0.5) && approxEq(v0[2], 0.5),
        "on-plane v0 should have X projected back: ("
        ~ v0[0].to!string ~ "," ~ v0[1].to!string ~ "," ~ v0[2].to!string ~ ")");
    postJson("/api/command", "tool.pipe.attr symmetry offset 0");
    postJson("/api/command", "tool.pipe.attr symmetry enabled false");
    postJson("/api/reset", "");
}

// -------------------------------------------------------------------------
// 7.6c: symmetric selection — picking one vertex / edge / face also
// selects its mirror counterpart when symmetry is on.
// -------------------------------------------------------------------------

JSONValue getSelection() {
    return parseJSON(cast(string) get(baseUrl ~ "/api/selection"));
}

int[] vertexSelection() {
    auto j = getSelection();
    int[] out_;
    foreach (idx; j["selectedVertices"].array)
        out_ ~= cast(int)idx.integer;
    return out_;
}

int[] edgeSelection() {
    auto j = getSelection();
    int[] out_;
    foreach (idx; j["selectedEdges"].array)
        out_ ~= cast(int)idx.integer;
    return out_;
}

int[] faceSelection() {
    auto j = getSelection();
    int[] out_;
    foreach (idx; j["selectedFaces"].array)
        out_ ~= cast(int)idx.integer;
    return out_;
}

bool selContains(int[] sel, int idx) {
    foreach (s; sel) if (s == idx) return true;
    return false;
}

unittest { // vertex pick adds mirror with symmetry on
    postJson("/api/reset", "");
    postJson("/api/command", "tool.pipe.attr symmetry enabled true");
    postJson("/api/command", "tool.pipe.attr symmetry axis x");
    postJson("/api/select", `{"mode":"vertices","indices":[0]}`);
    auto sel = vertexSelection();
    assert(selContains(sel, 0), "v0 missing from selection");
    assert(selContains(sel, 1),
        "v1 (X-mirror of v0) should be auto-selected; got " ~ sel.to!string);
    postJson("/api/command", "tool.pipe.attr symmetry enabled false");
    postJson("/api/reset", "");
}

unittest { // vertex pick: no mirror when symmetry is off
    postJson("/api/reset", "");
    postJson("/api/command", "tool.pipe.attr symmetry enabled false");
    postJson("/api/select", `{"mode":"vertices","indices":[0]}`);
    auto sel = vertexSelection();
    assert(selContains(sel, 0));
    assert(!selContains(sel, 1),
        "v1 must NOT be auto-selected when symmetry is off; got " ~ sel.to!string);
    postJson("/api/reset", "");
}

unittest { // edge pick adds mirror edge
    postJson("/api/reset", "");
    postJson("/api/command", "tool.pipe.attr symmetry enabled true");
    postJson("/api/command", "tool.pipe.attr symmetry axis x");
    // Cube edge 0 = (0,3): both verts on -X side → mirror edge is (1,2)
    // (both on +X). Pick edge 0; mirror should auto-add.
    postJson("/api/select", `{"mode":"edges","indices":[0]}`);
    auto edges = edgeSelection();
    assert(selContains(edges, 0), "edge 0 missing from selection");
    // Find the edge connecting verts 1 and 2 — that's the mirror.
    auto j = parseJSON(cast(string) get(baseUrl ~ "/api/model"));
    int mirrorEi = -1;
    foreach (i, e; j["edges"].array) {
        auto pair = e.array;
        int a = cast(int)pair[0].integer;
        int b = cast(int)pair[1].integer;
        bool hits12 = (a == 1 && b == 2) || (a == 2 && b == 1);
        if (hits12) { mirrorEi = cast(int)i; break; }
    }
    assert(mirrorEi >= 0, "couldn't locate mirror edge in mesh");
    assert(selContains(edges, mirrorEi),
        "mirror edge (verts 1↔2) idx=" ~ mirrorEi.to!string
        ~ " should be auto-selected; got " ~ edges.to!string);
    postJson("/api/command", "tool.pipe.attr symmetry enabled false");
    postJson("/api/reset", "");
}

unittest { // face pick adds mirror face
    postJson("/api/reset", "");
    postJson("/api/command", "tool.pipe.attr symmetry enabled true");
    postJson("/api/command", "tool.pipe.attr symmetry axis x");
    // Cube face 2 = -X face (vertex set {0,3,7,4}); X-mirror is face 3
    // = +X face (vertex set {1,2,6,5}). Pick face 2; auto-select 3.
    postJson("/api/select", `{"mode":"polygons","indices":[2]}`);
    auto faces = faceSelection();
    assert(selContains(faces, 2), "face 2 missing from selection");
    assert(selContains(faces, 3),
        "face 3 (mirror of -X face) should be auto-selected; got "
        ~ faces.to!string);
    postJson("/api/command", "tool.pipe.attr symmetry enabled false");
    postJson("/api/reset", "");
}

unittest { // face pick: a face symmetric to itself doesn't double-select
    postJson("/api/reset", "");
    postJson("/api/command", "tool.pipe.attr symmetry enabled true");
    postJson("/api/command", "tool.pipe.attr symmetry axis x");
    // Cube face 0 = -Z face (vertex set {0,1,2,3}); X-mirror is itself
    // (the face spans both sides of X=0). mirrorFace returns ~0u, the
    // selection should contain only face 0.
    postJson("/api/select", `{"mode":"polygons","indices":[0]}`);
    auto faces = faceSelection();
    assert(selContains(faces, 0), "face 0 missing");
    assert(faces.length == 1,
        "face 0 should be its own mirror across X — selection should be "
        ~ "length 1, got " ~ faces.length.to!string ~ " (" ~ faces.to!string ~ ")");
    postJson("/api/command", "tool.pipe.attr symmetry enabled false");
    postJson("/api/reset", "");
}

// -------------------------------------------------------------------------
// 7.6 (BaseSide): clicking a polygon on the +X side and translating
// PERPENDICULARLY to the symmetry plane gives symmetric expansion —
// both sides end up further from the plane by the same amount. Before
// the BaseSide drive rule, the lower-index side drove and a +X
// translate would push v0 across the plane, breaking the geometry.
// -------------------------------------------------------------------------

unittest { // pick +X face, translate +X → symmetric expansion
    postJson("/api/reset", "");
    postJson("/api/command", "tool.pipe.attr symmetry enabled true");
    postJson("/api/command", "tool.pipe.attr symmetry axis x");
    // face 3 = +X face ({1,2,6,5}). Auto-symmetry adds face 2 = -X
    // face ({0,4,7,3}). BaseSide should anchor on +X (face 3's centroid).
    postJson("/api/select", `{"mode":"polygons","indices":[3]}`);
    postJson("/api/transform",
        `{"kind":"translate","delta":[1,0,0]}`);
    // Expected (cube of half-extent 0.5 + +1 translate driven from +X):
    //   +X face verts (1,2,5,6) at x = +0.5 + 1 = +1.5
    //   -X face verts (0,3,4,7) at x = -(+1.5) = -1.5 (mirror write)
    foreach (i; [1, 2, 5, 6]) {
        auto v = vertexAt(i);
        assert(approxEq(v[0],  1.5),
            "v" ~ i.to!string ~ ".x expected +1.5, got " ~ v[0].to!string);
    }
    foreach (i; [0, 3, 4, 7]) {
        auto v = vertexAt(i);
        assert(approxEq(v[0], -1.5),
            "v" ~ i.to!string ~ ".x expected -1.5 (mirror), got " ~ v[0].to!string);
    }
    postJson("/api/command", "tool.pipe.attr symmetry enabled false");
    postJson("/api/reset", "");
}

unittest { // pick -X face, translate +X → symmetric collapse / cross-plane
    postJson("/api/reset", "");
    postJson("/api/command", "tool.pipe.attr symmetry enabled true");
    postJson("/api/command", "tool.pipe.attr symmetry axis x");
    // face 2 = -X face ({0,4,7,3}). Auto-symmetry adds face 3 = +X face.
    // BaseSide anchors on -X (face 2's centroid). User drags +X by 1
    // (TOWARD the plane and beyond), face 2 moves +X, face 3 follows
    // with mirrored delta (-X): both cross to the OTHER side at ±0.5.
    postJson("/api/select", `{"mode":"polygons","indices":[2]}`);
    postJson("/api/transform",
        `{"kind":"translate","delta":[1,0,0]}`);
    foreach (i; [0, 3, 4, 7]) {
        auto v = vertexAt(i);
        assert(approxEq(v[0],  0.5),
            "v" ~ i.to!string ~ " (-X face, base side, dragged +X): expected +0.5, got "
            ~ v[0].to!string);
    }
    foreach (i; [1, 2, 5, 6]) {
        auto v = vertexAt(i);
        assert(approxEq(v[0], -0.5),
            "v" ~ i.to!string ~ " (+X face, mirror): expected -0.5, got "
            ~ v[0].to!string);
    }
    postJson("/api/command", "tool.pipe.attr symmetry enabled false");
    postJson("/api/reset", "");
}

// -------------------------------------------------------------------------
// 7.6 (BaseSide use case): select with symmetry on, then turn symmetry
// OFF, then translate — both originally-symm-selected sides remain in
// the selection and move together as a single unit (no mirror pass).
// -------------------------------------------------------------------------

unittest { // pick face3 w/ symm, disable symm, translate → both faces move together
    postJson("/api/reset", "");
    postJson("/api/command", "tool.pipe.attr symmetry enabled true");
    postJson("/api/command", "tool.pipe.attr symmetry axis x");
    postJson("/api/select", `{"mode":"polygons","indices":[3]}`);
    // Selection should be both face 2 and face 3 at this point.
    assert(faceSelection().length == 2);
    // Turn off symmetry. Selection survives.
    postJson("/api/command", "tool.pipe.attr symmetry enabled false");
    assert(faceSelection().length == 2, "selection should survive symm off");
    // Translate +X. With symmetry off, NO mirror pass — both faces
    // shift by +X uniformly. Cube becomes a +X-translated cube.
    postJson("/api/transform",
        `{"kind":"translate","delta":[1,0,0]}`);
    foreach (i; 0 .. 8) {
        auto v = vertexAt(i);
        // Each vert's X = original_x + 1; original X was ±0.5.
        // So |X - sign*0.5 - 1| < eps where sign = sign(original).
        bool isPos = (i == 1 || i == 2 || i == 5 || i == 6);
        double want = isPos ? 1.5 : 0.5;
        assert(approxEq(v[0], want),
            "v" ~ i.to!string ~ " expected x=" ~ want.to!string
            ~ ", got " ~ v[0].to!string);
    }
    postJson("/api/reset", "");
}

// -------------------------------------------------------------------------
// 7.6 (BaseSide): /api/toolpipe/eval exposes baseSide and vertSign.
// -------------------------------------------------------------------------

// -------------------------------------------------------------------------
// 7.6 (BaseSide gizmo): when symmetry auto-adds the mirror polygon to the
// selection, the action center (gizmo position) lands on the BASE side,
// not on the symmetry plane. Without this filter the centroid of {face2,
// face3} would be (0,0,0) — gizmo clipped to axis instead of the picked
// half.
// -------------------------------------------------------------------------

unittest { // gizmo follows the picked half — face on +X
    postJson("/api/reset", "");
    postJson("/api/command", "tool.pipe.attr symmetry enabled true");
    postJson("/api/command", "tool.pipe.attr symmetry axis x");
    // We need a mode that uses selection centroid. Auto is the default
    // when ACEN is set; for deterministic test, force `select` mode.
    postJson("/api/command", "tool.pipe.attr actionCenter mode select");

    postJson("/api/select", `{"mode":"polygons","indices":[3]}`);
    auto j = getJson("/api/toolpipe/eval");
    auto c = j["actionCenter"]["center"].array;
    double cx = c[0].floating, cy = c[1].floating, cz = c[2].floating;
    // face 3 = +X face; its centroid is (+0.5, 0, 0).
    assert(approxEq(cx,  0.5) && approxEq(cy, 0.0) && approxEq(cz, 0.0),
        "gizmo center should be at face-3 centroid (+0.5,0,0); got ("
        ~ cx.to!string ~ "," ~ cy.to!string ~ "," ~ cz.to!string ~ ")");

    postJson("/api/command", "tool.pipe.attr actionCenter mode none");
    postJson("/api/command", "tool.pipe.attr symmetry enabled false");
    postJson("/api/reset", "");
}

unittest { // gizmo follows the picked half — face on -X
    postJson("/api/reset", "");
    postJson("/api/command", "tool.pipe.attr symmetry enabled true");
    postJson("/api/command", "tool.pipe.attr symmetry axis x");
    postJson("/api/command", "tool.pipe.attr actionCenter mode select");

    postJson("/api/select", `{"mode":"polygons","indices":[2]}`);
    auto j = getJson("/api/toolpipe/eval");
    auto c = j["actionCenter"]["center"].array;
    double cx = c[0].floating;
    assert(approxEq(cx, -0.5),
        "gizmo center on -X pick: expected x=-0.5, got " ~ cx.to!string);

    postJson("/api/command", "tool.pipe.attr actionCenter mode none");
    postJson("/api/command", "tool.pipe.attr symmetry enabled false");
    postJson("/api/reset", "");
}

unittest { // baseSide reflects pick anchor
    postJson("/api/reset", "");
    postJson("/api/command", "tool.pipe.attr symmetry enabled true");
    postJson("/api/command", "tool.pipe.attr symmetry axis x");
    postJson("/api/select", `{"mode":"polygons","indices":[3]}`);
    auto j = getJson("/api/toolpipe/eval");
    auto bs = j["symmetry"]["baseSide"].integer;
    assert(bs == 1, "+X pick should set baseSide=+1, got " ~ bs.to!string);

    postJson("/api/select", `{"mode":"polygons","indices":[2]}`);
    j = getJson("/api/toolpipe/eval");
    bs = j["symmetry"]["baseSide"].integer;
    assert(bs == -1, "-X pick should set baseSide=-1, got " ~ bs.to!string);

    auto vs = j["symmetry"]["vertSign"].array;
    assert(vs.length == 8, "vertSign should be 8 long");
    foreach (i; 0 .. 8) {
        // Even-index cube layout (0,3,4,7 are -X; 1,2,5,6 are +X).
        bool isPos = (i == 1 || i == 2 || i == 5 || i == 6);
        long want = isPos ? 1 : -1;
        assert(vs[i].integer == want,
            "vertSign[" ~ i.to!string ~ "] expected " ~ want.to!string
            ~ ", got " ~ vs[i].integer.to!string);
    }
    postJson("/api/command", "tool.pipe.attr symmetry enabled false");
    postJson("/api/reset", "");
}
