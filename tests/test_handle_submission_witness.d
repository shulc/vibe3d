// Handle registration and actual submission are separate facts. These cells
// join them by one completed overlay-pass generation and keep every positive
// control populated by named parts (task 5480 / task 5402). The declaration
// order is load-bearing: druntime stops this module on its first red assert,
// and the SplitH cell must never run without the earlier compact baseline.

import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import drag_helpers;

import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.algorithm : canFind, sort;
import std.conv : to;
import std.format : format;
import std.json : JSONType, JSONValue;

void main() {}

private long number(JSONValue value, string what) {
    if (value.type == JSONType.integer) return value.integer;
    if (value.type == JSONType.uinteger) return cast(long)value.uinteger;
    assert(false, what ~ " is not an integer: " ~ value.toString());
}

private void command(string line) {
    auto response = postJson("/api/command", line);
    assert(response["status"].str == "ok"
        || response["status"].str == "success",
        "command failed: " ~ line ~ " -> " ~ response.toString());
}

private void script(string line) {
    auto response = postJson("/api/script", line);
    assert(response["status"].str == "ok",
           "script failed: " ~ line ~ " -> " ~ response.toString());
}

private void setPerspective(string layout) {
    command("viewport.layout " ~ layout);
    command("viewport.view Perspective");
    auto response = postJson("/api/camera",
        `{"azimuth":0.5,"elevation":0.4,"distance":4.0,`
        ~ `"focus":{"x":0,"y":0,"z":0}}`);
    assert(response["status"].str == "ok",
           "perspective camera failed: " ~ response.toString());
}

private void resetSceneAndArm(string tool, string layout = "Single") {
    command(commandBody("scene.reset", `{}`));
    setPerspective(layout);
    command("tool.set " ~ tool);
}

private JSONValue snap() {
    return getJson("/api/frames/counts");
}

private long generation(JSONValue counts) {
    return number(counts["handlePass"]["generation"],
                  "handlePass.generation");
}

private void resetCounts() {
    auto response = postJson("/api/frames/counts/reset", `{}`);
    assert(response["status"].str == "ok",
           "frame-count reset failed: " ~ response.toString());
}

private JSONValue passAdvance(long n, string what) {
    const long first = generation(snap());
    JSONValue current;
    foreach (_; 0 .. 200) {
        current = snap();
        if (generation(current) >= first + n) return current;
        Thread.sleep(2.msecs);
    }
    assert(false, format("%s: handle-pass generation did not advance by %d "
                         ~ "after 200 polls (from %d to %d)",
                         what, n, first, generation(current)));
}

private JSONValue frameAdvance(long n, string what) {
    const long first = number(snap()["lastScene"]["seq"], "lastScene.seq");
    JSONValue current;
    foreach (_; 0 .. 200) {
        current = snap();
        const long seq = number(current["lastScene"]["seq"], "lastScene.seq");
        if (seq >= first + n) return current;
        Thread.sleep(2.msecs);
    }
    assert(false, format("%s: lastScene.seq did not advance by %d after 200 "
                         ~ "polls (from %d to %d)", what, n, first,
                         number(current["lastScene"]["seq"], "lastScene.seq")));
}

private void waitForNoHandles(string what) {
    enum int waitBudgetSeconds = 3;
    enum size_t maxPolls = 2000;
    const deadline = MonoTime.currTime + waitBudgetSeconds.seconds;
    string last = "<not polled>";
    size_t polls;
    while (polls < maxPolls && MonoTime.currTime < deadline) {
        auto handles = getJson("/api/tool/handles")["handles"];
        last = handles.toString();
        ++polls;
        if (handles.type == JSONType.null_) return;
        Thread.sleep(2.msecs);
    }
    assert(false, format("%s: /api/tool/handles did not become null within "
                         ~ "the %d-second wait budget (cap %d polls, observed "
                         ~ "%d; last=%s)", what, waitBudgetSeconds, maxPolls,
                         polls, last));
}

private struct Part {
    int id;
    bool visible;
    string drawId;
}

private struct Registry {
    Part[] parts;
    int captured;
    long drawGeneration;
    int planeRingsDrawn;
    bool hasPlaneRings;
    JSONValue raw;
}

private Registry registry() {
    auto handles = getJson("/api/tool/handles")["handles"];
    assert(handles.type == JSONType.object,
           "active tool published no handle registry: " ~ handles.toString());
    Registry result;
    result.raw = handles;
    result.captured = cast(int)number(handles["captured"], "handles.captured");
    result.drawGeneration = number(handles["drawGeneration"],
                                   "handles.drawGeneration");
    foreach (p; handles["parts"].array) {
        Part part;
        part.id = cast(int)number(p["part"], "handles.parts[].part");
        part.visible = p["visible"].type == JSONType.true_;
        part.drawId = p["drawId"].str;
        result.parts ~= part;
    }
    if (auto value = "planeRingsDrawn" in handles.object) {
        result.hasPlaneRings = true;
        result.planeRingsDrawn = cast(int)number(*value, "planeRingsDrawn");
    }
    return result;
}

private struct Joined {
    Registry reg;
    JSONValue counts;
}

private Joined joined(string what) {
    long lastRegGeneration;
    long beforeGeneration;
    long afterGeneration;
    foreach (_; 0 .. 5) {
        auto before = snap();
        auto r = registry();
        auto after = snap();
        lastRegGeneration = r.drawGeneration;
        beforeGeneration = generation(before);
        afterGeneration = generation(after);
        if (lastRegGeneration != 0 && lastRegGeneration == beforeGeneration)
            return Joined(r, before);
        if (lastRegGeneration != 0 && lastRegGeneration == afterGeneration)
            return Joined(r, after);
        Thread.sleep(2.msecs);
    }
    const string zeroDetail = lastRegGeneration == 0
        ? " registry was stamped outside a pass (0), and no later draw "
          ~ "re-registered it;" : "";
    assert(false, format("%s: bracketed registry/pass join failed;%s "
                         ~ "before=%d drawGeneration=%d after=%d",
                         what, zeroDetail, beforeGeneration,
                         lastRegGeneration, afterGeneration));
}

private int[] partIds(const Registry r) {
    int[] result;
    foreach (p; r.parts) result ~= p.id;
    result.sort();
    return result;
}

private Part part(const Registry r, int id) {
    foreach (p; r.parts) if (p.id == id) return p;
    assert(false, format("registered part %d is absent", id));
}

private string[] receiptIds(JSONValue counts) {
    string[] result;
    foreach (id; counts["handlePass"]["ids"].array) result ~= id.str;
    return result;
}

private bool sameStringSet(const(string)[] a, const(string)[] b) {
    auto ac = a.dup;
    auto bc = b.dup;
    ac.sort();
    bc.sort();
    return ac == bc;
}

private void assertPartSet(const Registry r, const(int)[] expected,
                           string cell) {
    assert(partIds(r) == expected,
           cell ~ ": registered part set changed: " ~ partIds(r).to!string);
}

private void assertAllVisible(const Registry r, string cell) {
    foreach (p; r.parts)
        assert(p.visible,
               format("%s: part %d is view-collapsed; the fixed camera no "
                    ~ "longer names the drawn population", cell, p.id));
}

private void assertDistinctDrawIds(const Registry r, string cell) {
    string[] seen;
    foreach (p; r.parts) {
        assert(!seen.canFind(p.drawId),
               format("%s: part %d aliases earlier drawId %s",
                      cell, p.id, p.drawId));
        seen ~= p.drawId;
    }
}

private void assertReceipt(const Registry r, JSONValue counts, int id,
                           string cell) {
    const string expected = part(r, id).drawId;
    const auto actual = receiptIds(counts);
    assert(actual.canFind(expected),
           format("%s: visible part %d has drawId %s but handlePass.ids is %s",
                  cell, id, expected, actual));
}

private void assertNoDrops(JSONValue counts, string cell) {
    assert(number(counts["handlePass"]["receiptsDropped"],
                  "handlePass.receiptsDropped") == 0,
           cell ~ ": the fixed receipt buffer overflowed");
}

private void assertGeneration(JSONValue counts, string cell) {
    assert(generation(counts) > 0,
           cell ~ ": handlePass.generation is zero; the registry/receipt "
           ~ "join has no completed generation");
}

private long submitted(JSONValue counts) {
    return number(counts["handlePass"]["submitted"], "handlePass.submitted");
}

private long writes(JSONValue counts) {
    return number(counts["handlePass"]["writes"], "handlePass.writes");
}

private long handleCalls(JSONValue counts) {
    return number(counts["lastScene"]["pass"]["handles"]["calls"],
                  "lastScene.pass.handles.calls");
}

private long gCompactWrites;
private long gCompactCalls;

// Cell 4 — uniform scale's only handle submits through ImGui, not GL.
unittest {
    resetSceneAndArm("xfrm.scaleUniform");
    scope(exit) command("tool.set xfrm.scaleUniform off");
    resetCounts();
    passAdvance(3, "cell 4 uniform rig");
    auto j = joined("cell 4 uniform rig");

    assertGeneration(j.counts, "cell 4(b0)");
    assertPartSet(j.reg, [23], "cell 4(a)");
    assert(j.reg.drawGeneration == generation(j.counts),
           "cell 4(b): registry and pass generations differ");
    assertNoDrops(j.counts, "cell 4(b)");
    assert(part(j.reg, 23).visible,
           "cell 4(b): uniform centre disc is off-camera or invalid");
    assert(number(j.counts["lastScene"]["cellsRendered"],
                  "lastScene.cellsRendered") == 1,
           "cell 4(b): Single layout did not render exactly one cell");
    assertReceipt(j.reg, j.counts, 23, "cell 4(c)");
    assert(submitted(j.counts) == 1 && writes(j.counts) == 1,
           format("cell 4(c): uniform disc expected submitted=1,writes=1; "
                  ~ "got %d,%d (check the fixed camera before the sink)",
                  submitted(j.counts), writes(j.counts)));
    assert(handleCalls(j.counts) == 0,
           format("cell 4(d): ImGui uniform disc unexpectedly reached the "
                  ~ "GL handle counter (%d calls)", handleCalls(j.counts)));
}

// Cell 3 — compact Transform, including proxy heads and one draw-only ring.
unittest {
    resetSceneAndArm("Transform");
    scope(exit) command("tool.set Transform off");
    resetCounts();
    passAdvance(3, "cell 3 compact rig");
    auto j = joined("cell 3 compact rig");

    static immutable int[] expected =
        [0, 1, 2, 3, 10, 11, 12, 13, 20, 21, 22];
    assertGeneration(j.counts, "cell 3(b0)");
    assertPartSet(j.reg, expected, "cell 3(a)");
    assertNoDrops(j.counts, "cell 3(b)");
    assertAllVisible(j.reg, "cell 3(b)");
    assert(j.reg.captured == -1,
           "cell 3(b): compact rig is dragging and drew feedback arrows");
    assert(number(j.counts["lastScene"]["cellsRendered"],
                  "lastScene.cellsRendered") == 1,
           "cell 3(b): Single layout did not render exactly one cell");
    assertDistinctDrawIds(j.reg, "cell 3(c)");
    assert(part(j.reg, 20).drawId != part(j.reg, 0).drawId,
           "cell 3(c): scale-head proxy collapsed onto Move arrow X");
    foreach (id; expected)
        assertReceipt(j.reg, j.counts, id, "cell 3(d)");
    assert(submitted(j.counts) == 12,
           format("cell 3(e): compact pass submitted %d identities; expected "
                ~ "11 registered plus RotateHandler.bgCircle", submitted(j.counts)));
    assert(writes(j.counts) >= 12,
           format("cell 3(f): compact writes %d is below its 12-identity floor",
                  writes(j.counts)));
    gCompactWrites = writes(j.counts);
    gCompactCalls = handleCalls(j.counts);
    assert(gCompactCalls > 0,
           "cell 3(f): compact rig made no GL handle submissions");
}

private void dragPixels(int x0, int y0, int x1, int y1, int steps = 2) {
    auto cam = fetchCamera();
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                             x0, y0, x1, y1, steps));
    Thread.sleep(140.msecs);
}

private void originPixel(out int x, out int y) {
    auto vp = viewportFromCamera(fetchCamera());
    float sx, sy;
    assert(projectToWindow(Vec3(0, 0, 0), vp, sx, sy),
           "create rig world origin is off-camera");
    x = cast(int)(sx + 0.5f);
    y = cast(int)(sy + 0.5f);
}

private void setAttr(string tool, string name, double value) {
    command(format("tool.attr %s %s %.9g", tool, name, value));
}

private void makeCylinderReady() {
    int cx, cy;
    originPixel(cx, cy);
    dragPixels(cx - 90, cy - 70, cx + 90, cy + 70);
    foreach (name; ["cenX", "cenY", "cenZ"])
        setAttr("prim.cylinder", name, 0.0);
    foreach (name; ["sizeX", "sizeY", "sizeZ"])
        setAttr("prim.cylinder", name, 1.0);
}

// Cell 6 — create intent is already pinned elsewhere; the new half joins the
// visible registered set to actual submissions (M13).
unittest {
    command(commandBody("scene.reset", `{"empty":true}`));
    command("history.clear");
    script("workplane.edit cenX:0 cenY:0 cenZ:0 rotX:0 rotY:0 rotZ:0");
    setPerspective("Single");
    command("tool.set prim.cylinder");
    scope(exit) script("tool.set prim.cylinder off");
    makeCylinderReady();
    resetCounts();
    passAdvance(3, "cell 6 create rig");
    auto j = joined("cell 6 create rig");

    static immutable int[] expected = [0, 1, 2, 3, 4, 5, 10, 11, 12, 13];
    assertGeneration(j.counts, "cell 6(b0)");
    assertPartSet(j.reg, expected, "cell 6(a)");
    foreach (id; [10, 11, 12, 13])
        assert(part(j.reg, id).visible,
               format("cell 6(a): mover part %d is not visible", id));
    size_t visibleCount;
    foreach (p; j.reg.parts) if (p.visible) ++visibleCount;
    assert(visibleCount >= 4, "cell 6(a): visible create population is below 4");
    assertNoDrops(j.counts, "cell 6(b)");
    assert(number(j.counts["lastScene"]["cellsRendered"],
                  "lastScene.cellsRendered") == 1,
           "cell 6(b): Single layout did not render exactly one cell");
    assert(j.reg.hasPlaneRings && j.reg.planeRingsDrawn == 0,
           format("cell 6(c): create intent reports %d plane rings; actual "
                ~ "submitted=%d (the intent pin predates this witness)",
                  j.reg.planeRingsDrawn, submitted(j.counts)));

    string[] expectedReceipts;
    foreach (id; [10, 11, 12, 13, 0, 1, 2, 3, 4, 5]) {
        auto p = part(j.reg, id);
        if (p.visible) {
            expectedReceipts ~= p.drawId;
            assertReceipt(j.reg, j.counts, id, "cell 6(d)");
        } else {
            assert(!receiptIds(j.counts).canFind(p.drawId),
                   format("cell 6(d): collapsed part %d unexpectedly submitted "
                        ~ "drawId %s", id, p.drawId));
        }
    }
    assert(sameStringSet(expectedReceipts, receiptIds(j.counts)),
           format("cell 6(d): visible registered drawIds %s do not equal "
                ~ "handlePass.ids %s", expectedReceipts, receiptIds(j.counts)));
    assert(submitted(j.counts) == visibleCount,
           format("cell 6(d): submitted=%d but visible registered population=%d",
                  submitted(j.counts), visibleCount));
}

// Cell 1 — full Move is the primary positive control and M1 target.
unittest {
    resetSceneAndArm("move");
    scope(exit) command("tool.set move off");
    resetCounts();
    passAdvance(3, "cell 1 Move rig");
    auto j = joined("cell 1 Move rig");

    static immutable int[] expected = [0, 1, 2, 3, 4, 5, 6];
    assertGeneration(j.counts, "cell 1(b0)");
    assertPartSet(j.reg, expected, "cell 1(a)");
    assertNoDrops(j.counts, "cell 1(b)");
    assertAllVisible(j.reg, "cell 1(b)");
    assert(number(j.counts["lastScene"]["cellsRendered"],
                  "lastScene.cellsRendered") == 1,
           "cell 1(b): Single layout did not render exactly one cell");
    assertDistinctDrawIds(j.reg, "cell 1(c)");
    foreach (id; expected)
        assertReceipt(j.reg, j.counts, id, "cell 1(d)");
    assert(submitted(j.counts) == 7,
           format("cell 1(e): Move submitted %d identities, expected 7",
                  submitted(j.counts)));
    assert(receiptIds(j.counts).length == 7,
           format("cell 1(f): wire ids length is %d, expected only the 7 "
                ~ "submitted entries", receiptIds(j.counts).length));
    assert(writes(j.counts) == 13,
           format("cell 1(f): Move writes=%d, expected 3*2 rings + 1 box "
                ~ "+ 3*2 arrows = 13", writes(j.counts)));
    assert(handleCalls(j.counts) == 13,
           format("cell 1(f): Move GL handle calls=%d, expected 13",
                  handleCalls(j.counts)));
}

// Cell 2 — generations advance while Move draws, then the last completed
// record remains sticky through rendered frames with no handle pass.
unittest {
    resetSceneAndArm("move");
    resetCounts();
    passAdvance(3, "cell 2 Move A");
    auto a = joined("cell 2 Move A");
    passAdvance(3, "cell 2 Move B");
    auto b = snap();

    static immutable int[] expected = [0, 1, 2, 3, 4, 5, 6];
    assertGeneration(a.counts, "cell 2(b0)");
    assertPartSet(a.reg, expected, "cell 2(a)");
    assertAllVisible(a.reg, "cell 2(a)");
    assert(a.reg.drawGeneration == generation(a.counts),
           "cell 2(a): A registry/pass generations differ");
    assertNoDrops(a.counts, "cell 2(a)");
    foreach (id; expected)
        assertReceipt(a.reg, a.counts, id, "cell 2(a)");
    assert(submitted(a.counts) == 7,
           "cell 2(a): named Move floor did not submit seven identities");
    assert(generation(b) > generation(a.counts),
           format("cell 2(f): generation did not advance (%d -> %d)",
                  generation(a.counts), generation(b)));
    assert(receiptIds(b) == receiptIds(a.counts)
           && submitted(b) == submitted(a.counts)
           && writes(b) == writes(a.counts),
           "cell 2(g): quiet Move passes changed their receipt content");

    command("tool.set move off");
    waitForNoHandles("cell 2(h)");
    auto offBaseline = snap();
    auto c = frameAdvance(3, "cell 2 tool off");
    auto handles = getJson("/api/tool/handles")["handles"];
    assert(handles.type == JSONType.null_,
           "cell 2(h): tool.set move off left a handle registry");
    assert(generation(c) != 0,
           "cell 2(i): beginFrame cleared the sticky handle-pass generation");
    assert(generation(c) == generation(offBaseline),
           format("cell 2(j): pass opened after tool off (%d -> %d)",
                  generation(offBaseline), generation(c)));
    assert(number(c["lastScene"]["handlePasses"],
                  "lastScene.handlePasses") == 0
           && number(c["lastScene"]["cellsRendered"],
                     "lastScene.cellsRendered") >= 1,
           format("cell 2(k): tool-off frame reports handlePasses=%d, "
                ~ "cellsRendered=%d",
                  number(c["lastScene"]["handlePasses"], "handlePasses"),
                  number(c["lastScene"]["cellsRendered"], "cellsRendered")));
    assert(receiptIds(c) == receiptIds(b)
           && submitted(c) == submitted(b) && writes(c) == writes(b),
           "cell 2(l): sticky handle-pass content changed after tool off");
}

// Cell 5 — two compact passes in one frame. It deliberately consumes the
// baseline written by cell 3 above; running this cell alone is invalid.
unittest {
    resetSceneAndArm("Transform", "SplitH");
    scope(exit) command("tool.set Transform off");
    resetCounts();
    passAdvance(4, "cell 5 SplitH compact rig");
    auto j = joined("cell 5 SplitH compact rig");

    static immutable int[] expected =
        [0, 1, 2, 3, 10, 11, 12, 13, 20, 21, 22];
    assertGeneration(j.counts, "cell 5(b0)");
    assertPartSet(j.reg, expected, "cell 5(a)");
    assertAllVisible(j.reg, "cell 5(a)");
    foreach (id; expected)
        assertReceipt(j.reg, j.counts, id, "cell 5(a)");
    assert(submitted(j.counts) == 12,
           "cell 5(a): compact pass did not submit 12 identities");
    assertNoDrops(j.counts, "cell 5(b)");
    const long cells = number(j.counts["lastScene"]["cellsRendered"],
                              "lastScene.cellsRendered");
    const long passes = number(j.counts["lastScene"]["handlePasses"],
                               "lastScene.handlePasses");
    assert(cells == 2, format("cell 5(b): SplitH rendered %d cells", cells));
    assert(passes == cells,
           format("cell 5(c): handlePasses=%d, cellsRendered=%d", passes, cells));
    assert(handleCalls(j.counts) > gCompactCalls,
           format("cell 5(d): second compact cell added no GL calls "
                ~ "(%d vs Single %d)", handleCalls(j.counts), gCompactCalls));
    assert(writes(j.counts) == gCompactWrites,
           format("cell 5(e): last pass accumulated writes across cells: "
                ~ "SplitH=%d, Single=%d", writes(j.counts), gCompactWrites));
    assert(submitted(j.counts) == 12,
           "cell 5(f): compact identity dedup changed after raw-write check");
}
