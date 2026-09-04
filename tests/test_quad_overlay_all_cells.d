// test_quad_overlay_all_cells.d — task 1650.
//
// THE DEFECT (owner's dogfood, 2026-08-20): in a Quad layout the tool gizmo
// drew only in the cell under the cursor. The overlay OWNER being the hovered
// cell is by design; every other cell is meant to draw a world-derived replica
// (`OverlayMode.Visual`). What stopped it was that the non-owner branch was
// gated on an enumerated list of concrete tool classes — `XfrmTransformTool`,
// `CommandWrapperTool`, or a falloff with no tool. `EdgeExtendTool` and
// `EdgeBevelTool` COMPOSE a transform wrapper rather than inheriting one, so
// both casts missed and their cells were told to draw nothing.
//
// The fix drops the list: the replica draws whenever anything is armed.
//
// TWO FLOWS, AND THE SECOND IS NOT OPTIONAL.
//
//   Flow A — the replica DRAWS. Quad, a tool armed, cursor in the owner cell;
//            every other cell must resolve to `Visual`, with pixels to back it.
//   Flow B — the OWNER'S INTERACTION SURVIVES. With replicas drawn in all four
//            cells, hovering and grabbing a handle in the owner cell must still
//            work. This is the whole purpose of `Tool.draw`'s `visualOnly`
//            contract, and it is the half that catches a tool which reads the
//            flag but gates the wrong sites: such a tool makes the visible bug
//            disappear and puts an invisible one in its place.
//
// THREE TRAPS THIS FILE IS BUILT AROUND.
//
//   1. A MOVE-BASED RIG IS GREEN EITHER WAY. move/rotate/scale ARE
//      `XfrmTransformTool` — inside the removed list — so their cells drew
//      replicas before the fix too. Both flows here arm a tool from OUTSIDE
//      the list (`edge.extend`, `edge.bevel`), and that choice is a checked
//      fact, not a comment: tests/unit/quad_overlay_eligibility_test.d asserts
//      neither class is an `XfrmTransformTool`/`CommandWrapperTool`, and goes
//      red if someone reparents them and quietly disarms this file.
//
//   2. UNDER `--test` THE LAYOUT IS SINGLE, and `cellCount > 1` makes the
//      hovered branch inert. A flow that forgot `viewport.layout` would pass
//      while proving nothing, so both flows assert `cellCount == 4` after
//      switching, and Flow B additionally refuses to run unless a non-owner
//      cell really did resolve to `Visual`.
//
//   3. "THE REPLICA IS DRAWN" ALONE IS NOT ENOUGH — hence Flow B.
//
// WHY THE PRIMARY ASSERTION READS THE DECISION, NOT PIXELS.
// `/api/viewport/display` reports each cell's `overlayMode` off
// `editor_app.resolveOverlayMode` — the very function the N-cell render loop
// branches on, not a re-derivation — so asserting it IS asserting the branch
// the defect lived in. A pixel count can pass on the wrong pixels; it is kept
// here as corroboration (the gizmo's ink must appear in a non-owner cell and
// vanish when the tool is dropped), not as the load-bearing check.
module test_quad_overlay_all_cells;


import http_client : testBaseUrl;
import http_command_helpers : commandBody;
import std.stdio     : writeln, writefln;
import std.net.curl  : HTTP;
import std.json      : parseJSON, JSONValue, JSONType;
import std.exception : enforce;
import std.conv      : to;
import std.format    : format;
import core.thread   : Thread;
import core.time     : msecs;

// --------------------------------------------------------------------------
// Helpers
// --------------------------------------------------------------------------

string baseUrl;

string httpGet(string path) {
    import std.net.curl : get;
    return cast(string)get(baseUrl ~ path);
}

string httpPost(string path, string body_) {
    auto http = HTTP();
    string result;
    http.onReceive = (ubyte[] data) { result ~= cast(string)data; return data.length; };
    http.postData = body_;
    http.addRequestHeader("Content-Type", "application/json");
    http.url = baseUrl ~ path;
    http.perform();
    return result;
}

void postCommand(string cmd, string params = "") {
    JSONValue j;
    j["id"] = cmd;
    if (params.length) j["params"] = params;
    string resp = httpPost("/api/command", j.toString);
    auto r = parseJSON(resp);
    enforce("status" !in r || r["status"].str != "error",
            "command " ~ cmd ~ " failed: " ~ resp);
}

void script(string s) {
    import std.string : indexOf;
    string resp = httpPost("/api/script", s);
    enforce(resp.indexOf(`"error"`) < 0,
            "script `" ~ s ~ "` failed: " ~ resp);
}

// The probe and the dump read the last COMPLETED frame (the HTTP bridge is
// serviced before the scene render), so anything that changes the scene needs
// a frame or two to land before it is visible.
void settle() { Thread.sleep(400.msecs); }

void resetApp() {
    httpPost("/api/reset", "{}");
    settle();
}

JSONValue displayDump() { return parseJSON(httpGet("/api/viewport/display")); }

bool jsonBool(JSONValue j, string[] path...) {
    JSONValue cur = j;
    foreach (k; path) cur = cur[k];
    enforce(cur.type == JSONType.TRUE || cur.type == JSONType.FALSE,
            "expected a bool at ." ~ path[$ - 1] ~ ", got " ~ cur.toString);
    return cur.type == JSONType.TRUE;
}

int jsonInt(JSONValue j, string[] path...) {
    JSONValue cur = j;
    foreach (k; path) cur = cur[k];
    switch (cur.type) {
        case JSONType.integer:  return cast(int)cur.integer;
        case JSONType.uinteger: return cast(int)cur.uinteger;
        case JSONType.float_:   return cast(int)cur.floating;
        default: throw new Exception("not a number at ." ~ path[$ - 1]);
    }
}

/// Whole-framebuffer digest of one cell. `renders` comes back too: a cell that
/// was not rendered has a never-filled FBO, and a hash taken off one would
/// compare equal for the wrong reason.
void cellHash(int cell, out string hash, out bool renders) {
    auto j = parseJSON(httpGet(format("/api/viewport/probe?cell=%d&hash=1", cell)));
    renders = jsonBool(j, "renders");
    enforce("hash" in j, "probe of cell " ~ cell.to!string ~ " returned no hash: "
            ~ j.toString);
    hash = j["hash"].str;
}

/// Switch to Quad and prove it took. Trap 2: without this the `cellCount > 1`
/// branch is inert and everything below passes while testing nothing.
JSONValue enterQuad() {
    postCommand("viewport.layout", "Quad");
    settle();
    auto j = displayDump();
    enforce(jsonInt(j, "cellCount") == 4,
        format("viewport.layout Quad did not take — cellCount is %d. Under "
               ~ "--test the layout invariant is Single, and with one cell the "
               ~ "hovered/owner branch this whole file is about is INERT: "
               ~ "every assertion below would pass without testing anything",
               jsonInt(j, "cellCount")));
    return j;
}

void restoreSingle() {
    try {
        script("tool.set edge.extend off");
        script("tool.set edge.bevel off");
        postCommand("viewport.layout", "Single");
        settle();
    } catch (Exception) { /* best effort — the runner shares one app */ }
}

/// Drive a JSON-Lines event log and wait for playback to finish.
void play(string log) {
    auto resp = httpPost("/api/play-events", log);
    auto j = parseJSON(resp);
    enforce(j["status"].str == "success", "play-events failed: " ~ resp);
    foreach (i; 0 .. 200) {
        auto s = parseJSON(httpGet("/api/play-events/status"));
        if (s["finished"].type == JSONType.TRUE) { settle(); return; }
        Thread.sleep(50.msecs);
    }
    throw new Exception("play-events did not finish within 10 s");
}

string motionAt(double t, int x, int y) {
    return format(`{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,`
                  ~ `"xrel":0,"yrel":0,"state":0,"mod":0}`, t, x, y);
}

string buttonAt(string type, int x, int y) {
    return format(`{"t":0.000,"type":"%s","btn":1,"x":%d,"y":%d,`
                  ~ `"clicks":1,"mod":0}`, type, x, y);
}

JSONValue handles() { return parseJSON(httpGet("/api/tool/handles"))["handles"]; }

// --------------------------------------------------------------------------
// Flow A — the replica draws in EVERY non-owner cell.
// --------------------------------------------------------------------------

bool testFlowA() {
    writeln("  [A] Quad + edge.extend: every non-owner cell draws the replica...");
    resetApp();
    scope(exit) restoreSingle();

    auto quad = enterQuad();

    // CONTROL, and it is what stops the main assertion from being a constant:
    // with nothing armed, every cell must resolve to None. If `Visual` were
    // hard-wired, this arm would fail.
    foreach (c; quad["cells"].array)
        enforce(c["overlayMode"].str == "None",
            format("cell %d reports overlayMode=%s with NO tool armed — the "
                   ~ "replica must be gated on something being drawn, or the "
                   ~ "main assertion below is a tautology",
                   jsonInt(c, "id"), c["overlayMode"].str));
    writeln("    A0 PASS: nothing armed ⇒ every cell None (the gate is real)");

    // Arm a tool from OUTSIDE the removed list (trap 1). `edge.extend` is a
    // plain `Tool` holding a transform wrapper, so both of the deleted casts
    // missed it and its non-owner cells used to be told to draw nothing.
    httpPost("/api/command", commandBody("mesh.select", `{"mode":"edges","indices":[0]}`));
    script("tool.set edge.extend on");
    settle();

    auto st = parseJSON(httpGet("/api/tool/state"));
    enforce("tool" in st && st["tool"].str == "edgeExtend",
        "precondition: the rig must be armed with edge.extend — a rig built on "
        ~ "move/rotate/scale is green whether or not the fix landed, because "
        ~ "those ARE the enumerated type. /api/tool/state says: " ~ st.toString);
    writeln("    A1 PASS: armed edge.extend — a tool outside the removed list");

    auto j = displayDump();
    enforce(jsonInt(j, "cellCount") == 4, "the layout must still be Quad");
    immutable int owner = jsonInt(j, "overlayOwner");
    enforce(owner >= 0 && owner < 4, "overlayOwner out of range");

    // The owner cell runs the interactive path...
    auto oc = j["cells"].array[owner];
    enforce(oc["overlayMode"].str == "Interactive",
        format("the overlay owner (cell %d) must be Interactive, got %s",
               owner, oc["overlayMode"].str));

    // ...and EVERY other cell draws the replica. This is the defect.
    int visual = 0;
    foreach (c; j["cells"].array) {
        immutable int id = jsonInt(c, "id");
        if (id == owner) continue;
        enforce(c["overlayMode"].str == "Visual",
            format("cell %d reports overlayMode=%s while edge.extend is armed "
                   ~ "in cell %d. Non-owner cells must draw the world-derived "
                   ~ "replica. `None` here is task 1650's defect: the "
                   ~ "eligibility gate enumerated tool TYPES "
                   ~ "(XfrmTransformTool / CommandWrapperTool), and "
                   ~ "EdgeExtendTool composes a transform wrapper instead of "
                   ~ "inheriting one, so both casts missed and its cells were "
                   ~ "told to draw nothing",
                   id, c["overlayMode"].str, owner));
        visual++;
    }
    enforce(visual == 3,
        format("expected three non-owner cells, counted %d", visual));
    writefln("    A2 PASS: cell %d Interactive, the other 3 Visual", owner);

    // PIXEL CORROBORATION — the decision above says the replica should draw;
    // this says something actually reached a non-owner cell's framebuffer.
    // Categorical (the buffer CHANGED), never a shading value: the lane runs
    // software GL.
    immutable int other = (owner == 0) ? 1 : 0;
    string armed, dropped, rearmed;
    bool r1, r2, r3;
    cellHash(other, armed, r1);
    enforce(r1,
        format("cell %d reports renders=false — its framebuffer was never "
               ~ "filled, so a hash taken off it means nothing", other));

    script("tool.set edge.extend off");
    settle();
    cellHash(other, dropped, r2);
    enforce(r2, "the non-owner cell must still render with no tool armed");
    enforce(armed != dropped,
        format("cell %d's framebuffer is byte-identical with edge.extend armed "
               ~ "and with it dropped — the cell reports overlayMode=Visual but "
               ~ "no gizmo ink reached its pixels", other));

    script("tool.set edge.extend on");
    settle();
    cellHash(other, rearmed, r3);
    enforce(r3, "the non-owner cell must render after re-arming");
    enforce(rearmed == armed,
        format("cell %d did not return to its armed image on re-arm (%s vs %s) "
               ~ "— the replica is not a deterministic function of the tool "
               ~ "state", other, rearmed, armed));
    writefln("    A3 PASS: cell %d's pixels change with the tool and return on "
             ~ "re-arm", other);
    return true;
}

// --------------------------------------------------------------------------
// Flow B — the property `visualOnly` exists to protect.
//
// Three replicas now run `activeTool.draw` under FOREIGN cell projections
// before the owner's own draw. Most tools do not honour the `visualOnly`
// contract — measured on this tree, only 10 of the 38 `Tool.draw` overrides
// read the flag at all, and 21 of the other 28 write `cachedVp` and/or run a
// full `ToolHandles` register/hit-test cycle unconditionally. `EdgeBevelTool`
// is one of those 21.
//
// What keeps that safe is `viewport.overlayDrawOrder`: every non-owner cell is
// visited FIRST and the owner LAST, so each foreign write is overwritten before
// the frame ends and no event handling interleaves inside a draw pass. This
// flow is the empirical check of that. If the ordering guarantee broke — or if
// a tool gated the wrong sites — the published handle anchor would carry a
// foreign cell's projection and the hover below would land on nothing.
// --------------------------------------------------------------------------

bool testFlowB() {
    writeln("  [B] Owner-cell hover and grab survive the replica draws...");
    resetApp();
    scope(exit) restoreSingle();

    enterQuad();

    // `edge.bevel`, also outside the removed list, and unlike edge.extend it
    // publishes a handle arbiter over HTTP (`/api/tool/handles`), which is
    // what lets this flow assert hover and capture rather than infer them.
    httpPost("/api/command", commandBody("mesh.select", `{"mode":"edges","indices":[0]}`));
    script("tool.set edge.bevel on");
    settle();

    auto st = parseJSON(httpGet("/api/tool/state"));
    enforce("tool" in st && st["tool"].str == "edgeBevel",
        "precondition: this flow must be armed with edge.bevel (outside the "
        ~ "removed list). /api/tool/state says: " ~ st.toString);

    // PRECONDITION, and it is the guard that stops this flow from being inert:
    // if no non-owner cell is drawing a replica, there is no foreign draw to
    // survive and a green result would mean nothing.
    auto j = displayDump();
    immutable int owner = jsonInt(j, "overlayOwner");
    int replicas = 0;
    foreach (c; j["cells"].array) {
        if (jsonInt(c, "id") == owner) continue;
        if (c["overlayMode"].str == "Visual") replicas++;
        enforce(jsonBool(c, "renders"),
            format("cell %d is not being rendered, so its replica draw never "
                   ~ "runs and this flow would prove nothing", jsonInt(c, "id")));
    }
    enforce(replicas == 3,
        format("only %d of 3 non-owner cells are drawing a replica — with no "
               ~ "foreign draw in the pass there is nothing for the owner's "
               ~ "interaction to survive, and this flow cannot fail", replicas));
    writefln("    B0 PASS: %d replicas drawn under foreign projections, owner "
             ~ "is cell %d", replicas, owner);

    // The handle anchor as PUBLISHED. Owner-last means this must be the
    // owner's projection; if a replica's registration survived, it would be
    // some other cell's, and the hover below would miss.
    auto h = handles();
    enforce(h.type != JSONType.null_,
        "edge.bevel published no handle arbiter — /api/tool/handles is null, "
        ~ "so this flow cannot check hit-testing at all");
    enforce(h["parts"].array.length >= 1, "no handle parts registered");
    auto part0 = h["parts"].array[0];
    immutable int part = jsonInt(part0, "part");
    enforce(part0["screen"].type != JSONType.null_,
        "the handle has no screen anchor (off-camera) — nothing to aim at");
    immutable int sx = cast(int)part0["screen"].array[0].floating;
    immutable int sy = cast(int)part0["screen"].array[1].floating;
    enforce(jsonInt(h, "hot") == -1 && jsonInt(h, "captured") == -1,
        "precondition: nothing may be hot or captured before the hover — "
        ~ "otherwise the assertions below cannot tell a fresh hit from a "
        ~ "leftover state");

    // HOVER. Twice: `queryMouse` reads the position the previous frame
    // published, so a single motion registers a stale cursor.
    play(motionAt(0.0, sx, sy) ~ "\n" ~ motionAt(30.0, sx, sy));
    auto hv = handles();
    enforce(jsonInt(hv, "hot") == part,
        format("hovering the OWNER cell's handle at (%d,%d) left hot=%d, "
               ~ "expected %d. The gizmo is drawn in four cells now; the "
               ~ "owner's registration must be the resident one when the frame "
               ~ "ends (viewport.overlayDrawOrder visits the owner LAST). A "
               ~ "miss here means a non-owner cell's projection won — the "
               ~ "replica made the visible bug go away and broke interaction "
               ~ "instead, which is exactly what `visualOnly` exists to "
               ~ "prevent", sx, sy, jsonInt(hv, "hot"), part));
    enforce(hv["parts"].array[0]["state"].str == "rollover",
        "the hovered part must report state=rollover, got "
        ~ hv["parts"].array[0]["state"].str);
    writefln("    B1 PASS: hover in cell %d makes part %d hot", owner, part);

    // GRAB.
    play(buttonAt("SDL_MOUSEBUTTONDOWN", sx, sy));
    auto hd = handles();
    enforce(jsonInt(hd, "captured") == part,
        format("mouse-down on the owner cell's handle left captured=%d, "
               ~ "expected %d — the handle is drawn but cannot be grabbed",
               jsonInt(hd, "captured"), part));
    auto sd = parseJSON(httpGet("/api/tool/state"));
    enforce("dragPart" in sd && jsonInt(sd, "dragPart") == part,
        "the tool must record the grabbed part as its dragPart, got "
        ~ sd.toString);
    writefln("    B2 PASS: mouse-down captures part %d (tool dragPart agrees)",
             part);

    // RELEASE — and the capture must clear, or the next gesture inherits it.
    play(buttonAt("SDL_MOUSEBUTTONUP", sx, sy));
    auto hu = handles();
    enforce(jsonInt(hu, "captured") == -1,
        format("mouse-up left captured=%d — the grab did not release",
               jsonInt(hu, "captured")));
    writeln("    B3 PASS: mouse-up releases the grab");
    return true;
}

// --------------------------------------------------------------------------
// Main
// --------------------------------------------------------------------------

int main(string[] args) {
    // Resolve the port assigned to this worker by run_test.d.
    baseUrl = testBaseUrl();

    writeln("=== test_quad_overlay_all_cells ===");
    int passed = 0, failed = 0;

    void run(bool function() fn, string name) {
        import liveness_gate : scenario;
        scenario(name);
        try {
            if (fn()) { writeln("  PASS: ", name); passed++; }
            else      { writeln("  FAIL: ", name); failed++; }
        } catch (Exception e) {
            writefln("  FAIL: %s — %s", name, e.msg);
            failed++;
        }
    }

    // Two flows, reported independently on purpose: a revert of the fix should
    // redden Flow A, and a broken `visualOnly`/ordering guarantee should redden
    // Flow B, and the run must be able to say WHICH.
    run(&testFlowA, "Flow A — every non-owner cell draws the replica");
    run(&testFlowB, "Flow B — the owner cell's hover and grab still work");

    // The runner shares one app across a worker's slice and its between-tests
    // reset covers neither the layout nor the armed tool.
    restoreSingle();

    writefln("\n%d passed, %d failed", passed, failed);
    return failed > 0 ? 1 : 0;
}
