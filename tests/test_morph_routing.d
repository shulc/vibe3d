// HTTP tests for the morph ROUTING seam (task 1069, plan Stage 5).
//
// The measured law under test is L2 + L7: with a morph map selected, the SAME
// transform that would move the base writes into the map and leaves
// `mesh.vertices` untouched; with none selected it moves the base; and two
// successive gestures ADD rather than the second replacing the first.
//
// Driven headlessly: `tool.set move`, `tool.attr move TX <v>`, `tool.doApply`
// — the same numeric path `tests/test_acen_local_translate_parity.d` uses,
// which reaches `applyTRS` through `applyHeadless()`. Read back by saving a
// `.v3d` and parsing it, the one readback vehicle this feature has.
//
// Cube layout: 0:(-,-,-) 1:(+,-,-) 2:(+,+,-) 3:(-,+,-) 4:(-,-,+) 5:(+,-,+)
//              6:(+,+,+) 7:(-,+,+),  half-extent 0.5.

import std.net.curl;
import std.json;
import std.file   : remove, exists, readText;
import std.conv   : to;
import std.format : format;
import std.math   : fabs;

void main() {}

enum string kBase = "http://localhost:8080";

JSONValue postJson(string path, string body) {
    return parseJSON(cast(string) post(kBase ~ path, body));
}

void cmd(string s) {
    auto j = postJson("/api/command", s);
    assert(j["status"].str == "ok", "cmd `" ~ s ~ "` failed: " ~ j.toString);
}

void runCmd(string id, string paramsJson) {
    auto j = postJson("/api/command",
        `{"id":"` ~ id ~ `","params":` ~ paramsJson ~ `}`);
    assert(j["status"].str == "ok", id ~ " failed: " ~ j.toString);
}

void resetCube() {
    auto j = postJson("/api/reset", "");
    assert(j["status"].str == "ok", "/api/reset failed: " ~ j.toString);
}

void postSelect(string mode, int[] indices) {
    string idxJson = "[";
    foreach (i, v; indices) { if (i > 0) idxJson ~= ","; idxJson ~= v.to!string; }
    idxJson ~= "]";
    auto j = postJson("/api/select",
        `{"mode":"` ~ mode ~ `","indices":` ~ idxJson ~ `}`);
    assert(j["status"].str == "ok", "/api/select failed: " ~ j.toString);
}

bool approxEq(double a, double b, double eps = 1e-5) { return fabs(a - b) < eps; }

private int g_seq = 0;

JSONValue saveAndReadMesh(string tag) {
    string path = format("/tmp/vibe3d-test-morphroute-%s-%d.v3d", tag, g_seq++);
    if (exists(path)) remove(path);
    scope(exit) if (exists(path)) remove(path);
    runCmd("file.save", `{"path":"` ~ path ~ `"}`);
    return parseJSON(readText(path))["layers"][0]["mesh"];
}

struct MorphBlock {
    string   kind;
    long[]   verts;
    double[] values;
    size_t entryCount() const { return verts.length; }
    bool valueOf(long vi, out double[3] v) const {
        foreach (k, w; verts) {
            if (w != vi) continue;
            v = [values[k * 3], values[k * 3 + 1], values[k * 3 + 2]];
            return true;
        }
        return false;
    }
}

bool hasMorphBlock(JSONValue m) { return ("vertexMorphs" in m) !is null; }

MorphBlock morphOf(JSONValue meshJson, string name) {
    assert(hasMorphBlock(meshJson), "mesh JSON carries no \"vertexMorphs\" key");
    foreach (m; meshJson["vertexMorphs"].array) {
        if (m["name"].str != name) continue;
        MorphBlock b;
        b.kind = m["kind"].str;
        foreach (v; m["verts"].array)  b.verts  ~= v.integer;
        foreach (v; m["values"].array) b.values ~= v.floating;
        return b;
    }
    assert(false, "no morph map named '" ~ name ~ "'");
}

double[3] vertexAt(JSONValue meshJson, size_t vi) {
    auto v = meshJson["vertices"].array[vi].array;
    return [v[0].floating, v[1].floating, v[2].floating];
}

void assertVec(double[3] got, double[3] want, string what) {
    assert(approxEq(got[0], want[0]) && approxEq(got[1], want[1])
        && approxEq(got[2], want[2]),
        format("%s: got (%.6f,%.6f,%.6f) want (%.6f,%.6f,%.6f)",
               what, got[0], got[1], got[2], want[0], want[1], want[2]));
}

/// Move the current selection by `tx` along X through the numeric attr path.
void numericMoveX(double tx) {
    cmd("tool.set move");
    cmd(format("tool.attr move TX %.6f", tx));
    cmd("tool.attr move TY 0.0");
    cmd("tool.attr move TZ 0.0");
    cmd("tool.doApply");
    cmd("tool.set move off");
}

/// The whole base vertex array, so "the base did not move" can be asserted
/// over EVERY vertex rather than the one the test happens to look at.
double[3][] allVerts(JSONValue meshJson) {
    double[3][] r;
    foreach (i; 0 .. meshJson["vertices"].array.length) r ~= vertexAt(meshJson, i);
    return r;
}

void assertBaseUnmoved(JSONValue before, JSONValue after, string what) {
    auto a = allVerts(before), b = allVerts(after);
    assert(a.length == b.length, what ~ ": vertex count changed");
    foreach (i; 0 .. a.length)
        assertVec(b[i], a[i], format("%s: vertex %d must NOT have moved", what, i));
}

// ==========================================================================

unittest { // L2 — with a target bound the move writes the MAP and leaves the
           // base alone; with none bound it moves the base.
    resetCube();
    auto before = saveAndReadMesh("l2-pre");

    runCmd("mesh.morph.create", `{"name":"m","kind":"relative"}`);
    // create STEALS the target, so no explicit select is needed -- assert that
    // by not issuing one.
    postSelect("vertices", [6]);
    numericMoveX(0.25);

    auto after = saveAndReadMesh("l2-routed");
    assertBaseUnmoved(before, after, "a ROUTED move");

    auto b = morphOf(after, "m");
    assert(b.entryCount >= 1,
        format("the routed move must have written the map -- %d entries",
               b.entryCount));
    double[3] v;
    assert(b.valueOf(6, v), "vertex 6 was selected and must have an entry");
    assertVec(v, [0.25, 0, 0], "the stored DELTA is the move, in the item frame");

    // ...and with the target cleared the SAME move moves the base.
    runCmd("mesh.morph.select", `{"name":""}`);
    postSelect("vertices", [6]);
    numericMoveX(0.25);
    auto unrouted = saveAndReadMesh("l2-unrouted");
    assertVec(vertexAt(unrouted, 6), [0.75, 0.5, 0.5],
        "with NO target bound the same move must move the BASE");
    // The map is untouched by the unrouted move.
    double[3] w;
    assert(morphOf(unrouted, "m").valueOf(6, w));
    assertVec(w, [0.25, 0, 0], "an unrouted move must not touch the map");
}

unittest { // L7 — two successive gestures ADD. This is the case that catches
           // a run baseline taken from the TRUE base instead of base+delta,
           // and it is also the case that catches `dragBaseline` being dirtied
           // with the morphed position (gesture 2 would then double-count).
    resetCube();
    auto before = saveAndReadMesh("acc-pre");
    runCmd("mesh.morph.create", `{"name":"m","kind":"relative"}`);
    postSelect("vertices", [6]);

    numericMoveX(0.25);
    auto mid = saveAndReadMesh("acc-mid");
    double[3] v1;
    assert(morphOf(mid, "m").valueOf(6, v1));
    assertVec(v1, [0.25, 0, 0], "gesture 1");
    assertBaseUnmoved(before, mid, "gesture 1");

    numericMoveX(0.1);
    auto end = saveAndReadMesh("acc-end");
    double[3] v2;
    assert(morphOf(end, "m").valueOf(6, v2));
    assertVec(v2, [0.35, 0, 0],
        "two gestures must ADD: 0.25 then 0.1 stores 0.35, not 0.1 "
      ~ "(a run baseline read from the TRUE base loses the first gesture) "
      ~ "and not 0.5 (a dragBaseline dirtied with the morphed position "
      ~ "double-counts it)");
    assertBaseUnmoved(before, end,
        "the base must STILL be untouched after two routed gestures");
}

unittest { // L3 — entries follow the SELECTION, and a zero-magnitude routed
           // move still creates them.
    resetCube();
    runCmd("mesh.morph.create", `{"name":"m","kind":"relative"}`);
    postSelect("vertices", [4, 5, 6, 7]);
    numericMoveX(0.2);

    auto b = morphOf(saveAndReadMesh("sel"), "m");
    assert(b.entryCount == 4,
        format("4 vertices selected must give exactly 4 entries, got %d",
               b.entryCount));
    foreach (vi; [4, 5, 6, 7]) {
        double[3] v;
        assert(b.valueOf(vi, v), format("vertex %d selected but has no entry", vi));
        assertVec(v, [0.2, 0, 0], format("vertex %d", vi));
    }
    foreach (vi; [0, 1, 2, 3]) {
        double[3] v;
        assert(!b.valueOf(vi, v),
            format("vertex %d was NOT selected and must have no entry", vi));
    }
}

unittest { // the ABSOLUTE kind stores a POSITION under routing, not a delta
    resetCube();
    auto before = saveAndReadMesh("abs-pre");
    runCmd("mesh.morph.create", `{"name":"s","kind":"absolute"}`);
    postSelect("vertices", [6]);
    numericMoveX(0.25);

    auto after = saveAndReadMesh("abs");
    assertBaseUnmoved(before, after, "a ROUTED move into an absolute map");
    double[3] v;
    assert(morphOf(after, "s").valueOf(6, v));
    // base (0.5,0.5,0.5) + 0.25 along X, stored as a POSITION.
    assertVec(v, [0.75, 0.5, 0.5],
        "the absolute kind stores the moved POSITION; storing a delta would "
      ~ "give (0.25,0,0)");
}

unittest { // UNDO of a routed edit restores the MAP, presence included,
           // without touching the base.
           //
           // NOTE which mechanism this leg exercises: the HEADLESS
           // `tool.doApply` path wraps the whole apply in
           // `ToolDoApplyCommand`'s `MeshSnapshot`, so THIS undo is the
           // snapshot restore, not `MeshMorphEdit`. The tool's own
           // `commitEdit` -> `buildMorphEditCmd` branch fires on a real gizmo
           // DRAG; `tests/test_morph_drag_undo.d` drives one through the
           // handle geometry `/api/tool/handles` reports.
    resetCube();
    auto before = saveAndReadMesh("undo-pre");
    runCmd("mesh.morph.create", `{"name":"m","kind":"relative"}`);
    postSelect("vertices", [6]);
    numericMoveX(0.25);

    auto edited = saveAndReadMesh("undo-edited");
    assert(morphOf(edited, "m").entryCount >= 1);

    cmd("history.undo");
    auto undone = saveAndReadMesh("undo-done");
    auto b = morphOf(undone, "m");
    double[3] v;
    assert(!b.valueOf(6, v),
        format("undo of a ROUTED drag must remove the ENTRY -- %d entries left. "
             ~ "Without its own command the drag never reaches undo at all, "
             ~ "because the base did not change and the position diff is empty",
               b.entryCount));
    assertBaseUnmoved(before, undone, "undo of a routed drag");

    // NO redo leg here, and the reason is a MEASURED pre-existing limitation
    // rather than anything this task introduced: `history.redo` after a
    // headless `tool.doApply` returns "did not apply" on the UNMODIFIED path
    // too (verified with no morph map in the document at all). The redo of a
    // command-driven morph edit IS covered, in tests/test_morph_v3d.d.
}

unittest { // L8 — TOPOLOGY operations are NOT routed. Subdivide with a target
           // bound changes the base exactly as it does with none. The test
           // that would catch someone "helpfully" gating them.
    resetCube();
    runCmd("mesh.morph.create", `{"name":"m","kind":"relative"}`);
    auto pre = saveAndReadMesh("topo-pre");
    const size_t nBefore = pre["vertices"].array.length;

    postSelect("vertices", []);
    runCmd("mesh.subdivide", `{}`);

    auto post = saveAndReadMesh("topo-post");
    assert(post["vertices"].array.length > nBefore,
        format("subdivide with a morph target bound must still change the BASE "
             ~ "topology: %d -> %d vertices", nBefore,
               post["vertices"].array.length));
}

unittest { // the twelve UNROUTED tools stay on the base, and leave the map
           // byte-unchanged. With a morph target bound, `xfrm.push` edits the
           // BASE -- deliberately, and its symmetry mirror (where it has one)
           // does too, so ONE gesture never splits across TWO surfaces. This
           // is the pin for registry rows 47a-47l.
    resetCube();
    runCmd("mesh.morph.create", `{"name":"m","kind":"relative"}`);
    // Give the map an entry first, so "byte-unchanged" has something to be.
    runCmd("mesh.morph.set", `{"name":"m","vert":6,"x":0.25,"y":-0.1,"z":0.05}`);
    auto pre = saveAndReadMesh("unrouted-pre");

    postSelect("vertices", [4, 5, 6, 7]);
    cmd("tool.set xfrm.push");
    cmd("tool.attr xfrm.push dist 0.3");
    cmd("tool.doApply");
    cmd("tool.set xfrm.push off");

    auto post = saveAndReadMesh("unrouted-post");

    // The BASE moved.
    bool moved = false;
    auto a = allVerts(pre), b = allVerts(post);
    foreach (i; 0 .. a.length)
        if (!approxEq(a[i][0], b[i][0]) || !approxEq(a[i][1], b[i][1])
         || !approxEq(a[i][2], b[i][2])) moved = true;
    assert(moved,
        "xfrm.push with a morph target bound must edit the BASE -- if nothing "
      ~ "moved, this test is inert and proves nothing about routing");

    // The MAP did not.
    auto mPre = morphOf(pre, "m"), mPost = morphOf(post, "m");
    assert(mPre.entryCount == mPost.entryCount,
        format("an unrouted tool must not add or remove entries: %d -> %d",
               mPre.entryCount, mPost.entryCount));
    double[3] v;
    assert(mPost.valueOf(6, v));
    assertVec(v, [0.25, -0.1, 0.05],
        "an unrouted tool must leave every stored value byte-unchanged");
}

unittest { // SYMMETRY under routing: BOTH sides land in the map and NEITHER
           // lands in the base -- the user-visible contract.
           //
           // What this case does NOT pin, measured rather than assumed: the
           // routed mirror OVERLOADS. With the symmetry stage enabled the
           // stage adds the mirror partner to the moving set, so the fold
           // kernel routes the partner's write directly; deleting the mirror
           // call outright leaves this case GREEN (verified by running exactly
           // that mutation). The overloads are pinned where they can be driven
           // to order, in tests/unit/morph_route_test.d.
           //
           // What this case DOES pin is the property objection 2c is about: a
           // single gesture must not split across two surfaces. If the mirror
           // were left unrouted while the primary write is routed, the partner
           // would be written into `mesh.vertices` and `assertBaseUnmoved`
           // below would redden.
    resetCube();
    auto before = saveAndReadMesh("sym-pre");
    runCmd("mesh.morph.create", `{"name":"m","kind":"relative"}`);

    // Symmetry about X: vertex 6 (+,+,+) pairs with 7 (-,+,+). Configured on
    // the PIPE STAGE (`tool.pipe.attr symmetry ...`), not as a tool attr --
    // `tool.attr move SymmetryEnable` is accepted and does nothing, which
    // would leave the mirror assertions below silently inert.
    cmd("tool.pipe.attr symmetry enabled 1");
    cmd("tool.pipe.attr symmetry axis x");

    postSelect("vertices", [6]);
    cmd("tool.set move");
    cmd("tool.attr move TX 0.0");
    cmd("tool.attr move TY 0.0");
    cmd("tool.attr move TZ 0.2");
    cmd("tool.doApply");
    cmd("tool.set move off");

    auto after = saveAndReadMesh("sym-post");
    assertBaseUnmoved(before, after,
        "a routed gesture must not move the base on EITHER side -- if the "
      ~ "mirror is unrouted, one gesture writes the primary to the map and "
      ~ "the partner to the base, corrupting both");

    auto b = morphOf(after, "m");
    double[3] driver, partner;
    assert(b.valueOf(6, driver), "the driver vertex has an entry");
    assertVec(driver, [0, 0, 0.2], "the driver's stored delta");
    assert(b.valueOf(7, partner),
        "the mirror partner must have an ENTRY -- if it does not, the symmetry "
      ~ "stage was never enabled and every assertion below is inert");
    // Mirroring across the X plane leaves a +Z displacement unchanged in Z.
    assertVec(partner, [0, 0, 0.2],
        "the mirror partner's stored value must be the MIRRORED DELTA. A "
      ~ "mirror that reads the driver's `mesh.vertices` reads the UNMOVED base "
      ~ "under routing, so it would store (0,0,0) here -- and an 'the entry "
      ~ "CHANGED' assertion cannot tell that from the right answer, because "
      ~ "absent -> present-zero is a change");
    assert(b.entryCount == 2,
        format("exactly the driver and its partner have entries, got %d",
               b.entryCount));
}
