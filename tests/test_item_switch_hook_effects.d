// Task 6355: production item factories must retain the active-layer hook.
// The discriminating observable is the morph-routing binding cleared by
// Session.transitionActiveLayerBeforeRefresh. GPU refresh and tool disarm are
// deliberately only controls: both were measured green with the hook removed.
// No scene.reset may occur after a morph binding is installed, because reset
// independently clears it. Both mesh layers carry map "m", so a stale binding
// can resolve on the new primary and is observable. The lifecycle door is
// single-consumer; another registrant would make this fixture fail loudly.

import core.thread : Thread;
import core.time : dur;
import http_client : getJson, postRaw;
import http_command_helpers : commandBody;
import std.format : format;
import std.json : JSONValue, parseJSON;
import std.math : fabs;

void main() {}

private void postOk(string body) {
    const response = postRaw("/api/command", body);
    const json = parseJSON(response);
    assert("error" !in json
        && (("status" !in json) || json["status"].str == "ok"
                                || json["status"].str == "success"),
        "command failed: " ~ response);
}

private void cmd(string script) { postOk(script); }
private void command(string id, string params = "{}") {
    postOk(commandBody(id, params));
}
private void settle(int ms = 180) { Thread.sleep(dur!"msecs"(ms)); }
private bool approxEq(double a, double b, double eps = 1e-5) {
    return fabs(a - b) < eps;
}

private JSONValue model() { return getJson("/api/model"); }
private JSONValue gpu() { return getJson("/api/gpu/face-vbo"); }
private JSONValue[] layers() { return getJson("/api/layers")["layers"].array; }

private size_t[] primaryIndices() {
    size_t[] result;
    foreach (i, layer; layers())
        if (layer["primary"].boolean) result ~= i;
    return result;
}

private double vertexX(size_t index = 0) {
    return model()["vertices"].array[index].array[0].floating;
}

private double[3][] allVerts() {
    double[3][] result;
    foreach (vertex; model()["vertices"].array)
        result ~= [vertex.array[0].floating, vertex.array[1].floating,
                   vertex.array[2].floating];
    return result;
}

private void assertVertsEqual(const double[3][] before,
                              const double[3][] after, string message) {
    assert(before.length == after.length,
        message ~ ": vertex population changed");
    foreach (i; 0 .. before.length)
        foreach (axis; 0 .. 3)
            assert(approxEq(before[i][axis], after[i][axis]),
                format("%s: vertex %d axis %d changed %.6f -> %.6f",
                       message, i, axis, before[i][axis], after[i][axis]));
}

private void resetCube() {
    command("scene.reset");
    command("history.clear");
    settle();
}

private void selectVertexZero() {
    command("mesh.select", `{"mode":"vertices","indices":[0]}`);
}

private void selectMorph(string name) {
    // postOk is a population floor: a missing map must refuse here instead of
    // making the later +0.5 assertion accidentally match an unbound fixture.
    command("mesh.morph.select", `{"name":"` ~ name ~ `"}`);
}

private void createMorph() {
    command("mesh.morph.create", `{"name":"m","kind":"relative"}`);
}

private void numericMoveX(double amount) {
    cmd("tool.set move");
    cmd(format("tool.attr move TX %.6f", amount));
    cmd("tool.attr move TY 0.0");
    cmd("tool.attr move TZ 0.0");
    cmd("tool.doApply");
    cmd("tool.set move off");
    settle();
}

private void buildTwoMorphLayers() {
    resetCube();
    createMorph();
    cmd("layer.add name:B");
    cmd("prim.sphere");
    createMorph();
    assert(primaryIndices() == [1],
        "6355 two-layer floor: B must be primary after creation");
    assert(model()["vertices"].array.length == 554,
        "6355 two-layer floor: B must be the 554-vertex sphere");
}

private void buildSeatOrderedMorphLayers() {
    buildTwoMorphLayers();
    command("layer.select", `{"index":0,"mode":"set"}`);
    command("layer.select", `{"index":1,"mode":"add"}`);
    command("layer.select", `{"index":0,"mode":"remove"}`);
    assert(primaryIndices() == [1],
        "6355 seat-order floor: B must be the only selected primary");
}

private void assertMovedBase(string cell) {
    const x = vertexX();
    assert(approxEq(x, 0.5),
        format("the base of the new primary did not move: the morph routing "
             ~ "binding survived the primary change (v0.x = %.6f, want +0.500000) [%s]",
               x, cell));
}

unittest { // S0: model/GPU population distinguishes cube from sphere
    resetCube();
    auto cubeModel = model();
    auto cubeGpu = gpu();
    assert(cubeModel["vertices"].array.length == 8
        && cubeGpu["vertCount"].integer == 8
        && cubeGpu["faceVertCount"].integer == 36,
        "6355 S0 floor: reset cube must be 8 vertices / 36 face vertices");
    cmd("layer.add name:B");
    cmd("prim.sphere");
    settle();
    auto sphereModel = model();
    auto sphereGpu = gpu();
    assert(sphereModel["vertices"].array.length == 554
        && sphereGpu["vertCount"].integer == 554
        && sphereGpu["faceVertCount"].integer == 3312,
        "6355 S0 floor: sphere must be 554 vertices / 3312 face vertices");
    assert(cubeModel["vertices"].array.length
        != sphereModel["vertices"].array.length,
        "6355 S0 floor: cube and sphere populations must differ");
}

unittest { // S1/Z: the numeric move path moves the base
    resetCube();
    selectVertexZero();
    numericMoveX(1.0);
    assert(approxEq(vertexX(), 0.5),
        format("6355 S1 numeric move did not move the base (v0.x=%.6f)",
               vertexX()));
}

unittest { // S2/Y: a live binding routes the move into the map
    resetCube();
    createMorph();
    selectMorph("m");
    const before = allVerts();
    selectVertexZero();
    numericMoveX(1.0);
    const after = allVerts();
    assertVertsEqual(before, after,
        "6355 S2 live morph routing must leave the base unchanged");
    assert(approxEq(vertexX(), -0.5),
        "6355 S2 routed move changed the base vertex");
}

unittest { // S3/X: a primary change does not break an explicitly unbound move
    buildTwoMorphLayers();
    selectMorph("m");
    selectMorph("");
    command("layer.select", `{"index":0,"mode":"set"}`);
    assert(primaryIndices() == [0] && model()["vertices"].array.length == 8,
        "6355 S3 control: layer.select did not expose cube A");
    selectVertexZero();
    numericMoveX(1.0);
    assertMovedBase("S3 control");
}

unittest { // S4/W3: layer.select must clear the live morph binding
    buildTwoMorphLayers();
    selectMorph("m");
    command("layer.select", `{"index":0,"mode":"set"}`);
    settle();
    const p = primaryIndices();
    const m = model();
    const g = gpu();
    assert(p == [0] && m["vertices"].array.length == 8
        && g["vertCount"].integer == 8
        && g["faceVertCount"].integer == 36,
        "6355 S4 control: primary/model/GPU did not switch to cube A; this control is green even when the hook is lost");
    selectVertexZero();
    numericMoveX(1.0);
    assertMovedBase("S4 layer.select");
}

unittest { // Q control: imagePlane.add does not break an unbound move
    buildSeatOrderedMorphLayers();
    selectMorph("m");
    selectMorph("");
    command("imagePlane.add");
    assert(primaryIndices() == [0] && layers().length == 3,
        "6355 Q control: imagePlane.add did not expose cube A");
    selectVertexZero();
    numericMoveX(1.0);
    assertMovedBase("Q control");
}

unittest { // S5/P3: imagePlane.add must clear the live morph binding
    buildSeatOrderedMorphLayers();
    selectMorph("m");
    command("imagePlane.add");
    settle();
    const p = primaryIndices();
    const m = model();
    const g = gpu();
    assert(p == [0] && layers().length == 3
        && m["vertices"].array.length == 8
        && g["vertCount"].integer == 8
        && g["faceVertCount"].integer == 36,
        "6355 S5 control: primary/model/GPU did not switch to cube A; this control is green even when the hook is lost");
    selectVertexZero();
    numericMoveX(1.0);
    assertMovedBase("S5 imagePlane.add");
}

unittest { // S6: one mesh means no primary transition and no hook delivery
    resetCube();
    const before = getJson("/api/changes")["totalLayerActive"].integer;
    command("imagePlane.add");
    settle();
    const after = getJson("/api/changes")["totalLayerActive"].integer;
    assert(primaryIndices() == [0] && model()["vertices"].array.length == 8,
        "6355 S6 floor: a single-mesh document must retain cube A as primary");
    assert(after == before,
        format("6355 S6: imagePlane.add without a primary change must not call the hook (totalLayerActive %d -> %d)",
               before, after));
}

unittest { // S8: undo restores the prior edit target (control, not hook witness)
    buildSeatOrderedMorphLayers();
    command("history.clear");
    command("imagePlane.add");
    settle();
    assert(primaryIndices() == [0] && model()["vertices"].array.length == 8
        && gpu()["faceVertCount"].integer == 36,
        "6355 S8 floor: imagePlane.add did not expose cube A");
    command("history.undo");
    settle();
    assert(primaryIndices() == [1] && model()["vertices"].array.length == 554
        && gpu()["faceVertCount"].integer == 3312,
        "6355 S8: undo did not restore sphere B as the edit target");
}
