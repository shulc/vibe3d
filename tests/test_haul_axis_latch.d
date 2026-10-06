// Free-haul channel election through the delivered SDL event path.
import slice_leak_helpers : slCmd, slLineUi, slPlay, slMesh, cell, SL_KMOD_LCTRL;
import drag_helpers : fetchCamera;
import http_client : getJson;
import std.format : format;
import std.json;
import std.math : abs;

void main() {}

string motion(int t, int x, int y, int state, int mod) {
    return format(`{"t":%d,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":%d,"mod":%d}`, t,x,y,state,mod);
}
string button(int t, bool down, int x, int y, int mod) {
    return format(`{"t":%d,"type":"%s","btn":1,"x":%d,"y":%d,"clicks":1,"mod":%d}`, t,down ? "SDL_MOUSEBUTTONDOWN" : "SDL_MOUSEBUTTONUP",x,y,mod);
}
double value(JSONValue state, string key) {
    const v = state[key];
    return v.type == JSONType.integer ? cast(double)v.integer : v.floating;
}

void checkHaul(string family, string path) {
    const id = family ~ "-" ~ path;
    if (!cell(id)) return;
    const bevel = family == "bevel";
    const vertical = bevel ? "shift" : "extrude";
    const horizontal = bevel ? "inset" : "width";
    slCmd("scene.reset", `{"type":"cube"}`);
    slCmd("mesh.select", bevel ? `{"mode":"polygons","indices":[0]}` : `{"mode":"edges","indices":[0]}`);
    slLineUi(bevel ? "tool.set poly.bevel on" : "tool.set edge.extrude on");
    const initial = slMesh();
    const state0 = getJson("/api/tool/state");
    assert(initial.verts >= 8 && state0["tool"].str == (bevel ? "polyBevel" : "edgeExtrude"), id ~ " rig population/tool");
    const v0 = value(state0, vertical), h0 = value(state0, horizontal);
    const camera = fetchCamera();
    const x = camera.vpX + 70, y = camera.vpY + camera.height - 70;
    const ordinary = path == "ordinary" || path == "late-ctrl";
    const mod = ordinary ? 0 : SL_KMOD_LCTRL;
    string log = motion(20,x,y,0,mod) ~ "\n" ~ button(40,true,x,y,mod) ~ "\n";
    int dx = path == "two-pixel" ? 2 : path == "tie" ? 3 : 1;
    int dy = path == "tie" ? -3 : 0;
    if (path == "first-zero") log ~= motion(50,x,y,1,mod) ~ "\n";
    log ~= motion(70,x+dx,y+dy,1,mod) ~ "\n";
    const mod2 = path == "release-repress" ? 0 : path == "late-ctrl" ? SL_KMOD_LCTRL : mod;
    log ~= motion(100,x+dx,y-20,1,mod2) ~ "\n";
    const mod3 = path == "release-repress" || path == "late-ctrl" ? SL_KMOD_LCTRL : mod;
    log ~= motion(130,x+dx,y-40,1,mod3) ~ "\n" ~ button(160,false,x+dx,y-40,mod3);
    slPlay(log,id);
    const state = getJson("/api/tool/state");
    assert(state["tool"].str == state0["tool"].str, id ~ " tool survives haul");
    const v = value(state,vertical), h = value(state,horizontal);
    const geometry = slMesh();
    assert(geometry.verts >= 8, id ~ " live geometry population");
    if (ordinary) {
        assert(v > v0 && h > h0, format("%s both channels from ordinary press: %s/%s",id,v,h));
    } else if (path == "tie") {
        assert(v > v0, id ~ " vertical tie channel moves");
        assert(abs(h-h0) < 1e-7, format("%s vertical tie holds horizontal: %s",id,h));
    } else {
        assert(h > h0, id ~ " first horizontal channel moves");
        assert(abs(v-v0) < 1e-7, format("%s first horizontal motion holds vertical: %s",id,v));
    }
    if (!bevel && path == "tie")
        assert(geometry.canon == initial.canon, id ~ " zero-width extrusion keeps geometry");
    else
        assert(geometry.canon != initial.canon, id ~ " live geometry changed");
}

unittest {
    enum families = ["bevel", "extrude"];
    enum paths = ["one-pixel", "two-pixel", "tie", "release-repress", "first-zero", "ordinary", "late-ctrl"];
    assert(families.length * paths.length == 14, "SDL haul cell population");
    size_t delivered;
    foreach (family; families) foreach (path; paths)
        if (cell(family ~ "-" ~ path)) {
            checkHaul(family,path);
            ++delivered;
        }
    assert(delivered > 0, "at least one SDL haul cell must run");
}
