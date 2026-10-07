import camera_lens_control_helpers;
// Real held-handle motions must update geometry as well as properties.

import http_client : testBaseUrl, getJson, quiesce;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.conv : to;
import std.format : format;
import std.math : fabs, sqrt;

import drag_helpers;

void main() {}

alias BASE = testBaseUrl;


void cmd(string text) {
    auto r = parseJSON(cast(string)post(BASE ~ "/api/command", text));
    assert(r["status"].str == "ok", "command failed: " ~ text ~ " → " ~ r.toString);
}

void interactiveCmd(string text) {
    auto r = parseJSON(cast(string)post(BASE ~ "/api/script?interactive=true", text));
    assert(r["status"].str == "ok", "interactive command failed: " ~ text ~ " → " ~ r.toString);
}


void settle() { quiesce(); }

void play(string log) {
    playAndWaitLensControl(log, BASE);
    settle(); // Let frame-driven tool/preview updates observe the delivered input.
}

void navigate(bool redo) {
    play(format(
        `{"t":0.000,"type":"SDL_KEYDOWN","sym":122,"scan":0,"mod":%d,"repeat":0}`,
        redo ? 65 : 64));
}

string motion(double t, int x, int y, int state = 1) {
    return format(`{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":%d,"mod":0}`,
                  t, x, y, state);
}

string button(string kind, double t, int x, int y) {
    return format(`{"t":%.3f,"type":"%s","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`,
                  t, kind, x, y);
}

long modelDepth() { return getJson("/api/undo/status")["modelDepth"].integer; }

JSONValue model() { return getJson("/api/model"); }

int edgeIndex(JSONValue m, int a, int b) {
    foreach (i, e; m["edges"].array) {
        int x = cast(int)e.array[0].integer, y = cast(int)e.array[1].integer;
        if ((x == a && y == b) || (x == b && y == a)) return cast(int)i;
    }
    return -1;
}

void selectTopFrontEdge() {
    auto m = model();
    int ei = edgeIndex(m, 6, 7);
    assert(ei >= 0, "cube top-front edge missing");
    auto r = parseJSON(cast(string)post(BASE ~ "/api/command", commandBody("mesh.select", `{"mode":"edges","indices":[` ~ ei.to!string ~ `]}`)));
    assert(r["status"].str == "ok", "edge selection failed");
}


string geometry() { auto m = model(); return m["vertices"].toString ~ m["faces"].toString; }

// Compute the positive direction from the published handle and selected-source
// bounds centre. The production bank chooses the frame; the test chooses only
// a positive distance along its visible arm.
int[4] heldMotion(int part, Vec3 origin, int pixels = 15) {
    double sx, sy; bool found;
    fetchHandlePart(part, sx, sy, found, BASE);
    assert(found, "LIVE HANDLE: requested part exists");
    auto vp = viewportFromCamera(fetchCamera(BASE));
    float ox, oy;
    assert(projectToWindow(origin, vp, ox, oy), "LIVE HANDLE: origin projects");
    double dx=sx-ox, dy=sy-oy, length=sqrt(dx*dx+dy*dy);
    assert(length>5, "LIVE HANDLE: populated projected arm");
    int x=cast(int)sx, y=cast(int)sy;
    int tx=x+cast(int)(pixels*dx/length), ty=y+cast(int)(pixels*dy/length);
    play(motion(0,x,y,0) ~ "\n" ~ motion(.03,x,y,0));
    play(button("SDL_MOUSEBUTTONDOWN",0,x,y));
    assert(getJson("/api/tool/state")["dragPart"].integer==part,
        "LIVE HANDLE: actual requested part captured");
    play(motion(0,tx,ty));
    return [x,y,tx,ty];
}
void release(int[4] d) { play(button("SDL_MOUSEBUTTONUP",0,d[2],d[3])); }

void checkSequence(Vec3 origin, int level=0, bool widthMode=false) {
    cmd("tool.set edge.bevel on");
    interactiveCmd("tool.attr edge.bevel roundLevel "~level.to!string);
    interactiveCmd("tool.attr edge.bevel widthMode "~(widthMode ? "true" : "false"));
    settle();
    string source=geometry();
    auto d=heldMotion(0,origin);
    auto state=getJson("/api/tool/state");
    double width=state["width"].floating;
    string first=geometry();
    assert(width>0 && first!=source && state["built"].type==JSONType.true_,
        "LIVE WIDTH: held gesture changes actual geometry");
    release(d);
    d=heldMotion(1,origin);
    state=getJson("/api/tool/state");
    assert(state["miterOffset"].floating>0 && fabs(state["width"].floating-width)<1e-6,
        "LIVE OFFSET: positive independent scalar reached production");
    string offset=geometry();
    assert(offset!=source && offset!=first && state["built"].type==JSONType.true_,
        "LIVE OFFSET: held part1 changes geometry instead of erasing width preview");
    double miter=state["miterOffset"].floating;
    release(d);
    d=heldMotion(0,origin);
    state=getJson("/api/tool/state");
    assert(state["width"].floating>width && fabs(state["miterOffset"].floating-miter)<1e-6,
        "LIVE WIDTH AFTER OFFSET: independent scalar survives");
    assert(geometry()!=offset && geometry()!=source && state["built"].type==JSONType.true_,
        "LIVE WIDTH AFTER OFFSET: actual geometry continues changing");
    release(d);
    cmd("tool.set edge.bevel off");
}

unittest { // task20261330: ordinary endpoint support, before either release
    foreach(mode;0..3) {
        cmd(commandBody("scene.reset", `{"type":"cube"}`));
        selectTopFrontEdge();
        checkSequence(Vec3(0,.5f,.5f),mode==1?1:0,mode==2);
    }
}

unittest { // the previously supported J3 must use the same live preview route
    import std.file : readText;
    auto source=parseJSON(readText("tests/fixtures/edge_bevel/offset_junction.json"))["source"];
    cmd(commandBody("scene.loadMesh", `{"vertices":`~source["vertices"].toString~
        `,"faces":`~source["faces"].toString~`}`));
    auto m=model(); string indices;
    Vec3 low, high; bool populated;
    foreach(pair;source["selection"]["edges"].array) {
        int ei=edgeIndex(m,cast(int)pair[0].integer,cast(int)pair[1].integer);
        assert(ei>=0,"LIVE J3: source edge exists");
        if(indices.length) indices~=","; indices~=ei.to!string;
        foreach(vertex;pair.array) {
            auto row=source["vertices"][vertex.integer];
            auto v=Vec3(cast(float)row[0].floating,cast(float)row[1].floating,cast(float)row[2].floating);
            if(!populated) { low=high=v; populated=true; }
            else {
                import std.algorithm : min,max;
                low=Vec3(min(low.x,v.x),min(low.y,v.y),min(low.z,v.z));
                high=Vec3(max(high.x,v.x),max(high.y,v.y),max(high.z,v.z));
            }
        }
    }
    assert(populated,"LIVE J3: source selected population");
    cmd(commandBody("mesh.select",`{"mode":"edges","indices":[`~indices~`]}`));
    checkSequence((low+high)*.5f);
}

unittest { // Actual user ring selection, including the crash's nonzero offset.
    import std.file : readText;
    auto fixture=parseJSON(readText("tests/fixtures/edge_bevel/offset_ring.json"));
    auto source=fixture["source"];
    foreach(initialOffset;[0.0,.222]) {
        cmd(commandBody("scene.loadMesh", `{"vertices":`~source["vertices"].toString~
            `,"faces":`~source["faces"].toString~`}`));
        auto m=model(); string indices;
        foreach(pair;fixture["selection"]["edges"].array) {
            int ei=edgeIndex(m,cast(int)pair[0].integer,cast(int)pair[1].integer);
            assert(ei>=0,"LIVE RING: source edge exists");
            if(indices.length) indices~=",";indices~=ei.to!string;
        }
        cmd(commandBody("mesh.select",`{"mode":"edges","indices":[`~indices~`]}`));
        cmd("tool.set edge.bevel on");
        interactiveCmd("tool.attr edge.bevel miterOffset "~initialOffset.to!string);
        settle();
        auto before=geometry();
        auto d=heldMotion(0,Vec3(0,0,0),8);
        auto state=getJson("/api/tool/state");
        assert(state["width"].floating>0 && fabs(state["miterOffset"].floating-initialOffset)<1e-6,
            "LIVE RING: actual first handle changes width, preserves offset");
        assert(state["built"].type==JSONType.true_ && geometry()!=before,
            "LIVE RING: geometry changes before releasing the first handle");
        release(d);
        cmd("tool.set edge.bevel off");
    }
}

unittest { // task 20261470: zero-width offset is a live ring edit.
    import std.file : readText;
    auto fixture = parseJSON(readText("tests/fixtures/edge_bevel/zero_width_ring.json"));
    auto source = fixture["source"];
    cmd(commandBody("scene.loadMesh", `{"vertices":` ~ source["vertices"].toString ~
        `,"faces":` ~ source["faces"].toString ~ `}`));
    auto m = model(); string indices;
    foreach (pair; fixture["selection"]["edges"].array) {
        int ei = edgeIndex(m, cast(int)pair[0].integer, cast(int)pair[1].integer);
        assert(ei >= 0, "LIVE ZERO WIDTH: source selected edge exists");
        if (indices.length) indices ~= ",";
        indices ~= ei.to!string;
    }
    cmd(commandBody("mesh.select", `{"mode":"edges","indices":[` ~ indices ~ `]}`));
    cmd("tool.set edge.bevel on");
    interactiveCmd("tool.attr edge.bevel widthMode true");
    interactiveCmd("tool.attr edge.bevel width 0");
    interactiveCmd("tool.attr edge.bevel miterOffset 0");
    settle();
    const original = geometry();
    auto d = heldMotion(1, Vec3(.026f, .138f, -.038f));
    auto state = getJson("/api/tool/state");
    const first = geometry();
    assert(state["width"].floating == 0 && state["miterOffset"].floating > 0,
        "LIVE ZERO WIDTH: independent offset changes while width stays zero");
    assert(state["built"].type == JSONType.true_ && first != original && model()["vertexCount"].integer == 108,
        "LIVE ZERO WIDTH: held offset builds the complete ring geometry");
    release(d);
    const before = state["miterOffset"].floating;
    d = heldMotion(1, Vec3(.026f, .138f, -.038f));
    state = getJson("/api/tool/state");
    assert(state["width"].floating == 0 && state["miterOffset"].floating > before && geometry() != first,
        "LIVE ZERO WIDTH: second offset gesture changes complete geometry again");
    release(d);
    cmd("tool.set edge.bevel off");
}
