// Activation-time falloff sizing for every shipped preset whose falloff owns
// layer-sized geometry. The fixture is deliberately asymmetric and off-origin
// so centre, axis extent, diagonal and a radial size cannot coincide.

import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import std.conv : to;
import std.format : format;
import std.json : JSONValue;
import std.math : fabs;
import std.string : split;

void main() {}

void cmd(string argstring) {
    auto r = postJson("/api/command", argstring);
    assert(r["status"].str == "ok",
        "cmd `" ~ argstring ~ "` failed: " ~ r.toString());
}

string[string] falloffAttrs() {
    auto pipe = getJson("/api/toolpipe");
    foreach (stage; pipe["stages"].array) {
        if (stage["task"].str != "WGHT") continue;
        string[string] attrs;
        foreach (name, value; stage["attrs"].object)
            attrs[name] = value.str;
        return attrs;
    }
    assert(false, "WGHT stage missing from /api/toolpipe");
}

float[3] vec3(string wire) {
    auto parts = wire.split(",");
    assert(parts.length == 3, "invalid Vec3 wire value: " ~ wire);
    return [parts[0].to!float, parts[1].to!float, parts[2].to!float];
}

bool near(float[3] a, float[3] b, float eps = 1e-5f) {
    foreach (i; 0 .. 3)
        if (fabs(a[i] - b[i]) > eps) return false;
    return true;
}

void buildRig(float sizeX = 4.0f, float sizeY = 1.0f, float sizeZ = 0.5f,
              string workplaneMode = "worldY") {
    auto reset = postJson("/api/command",
        commandBody("scene.reset", `{"empty":true}`));
    assert(reset["status"].str == "ok", "scene.reset failed: " ~ reset.toString());
    cmd("select.typeFrom vertex");
    cmd(format("prim.cube cenX:3 cenY:2 cenZ:-1 sizeX:%g sizeY:%g sizeZ:%g "
        ~ "segmentsX:4 segmentsY:2 segmentsZ:2 radius:0",
        sizeX, sizeY, sizeZ));
    cmd("tool.pipe.attr workplane mode " ~ workplaneMode);
    auto model = getJson("/api/model");
    assert(model["vertexCount"].integer == 42,
        "falloff auto-fit fixture population changed: expected 42 vertices, got "
        ~ model["vertexCount"].integer.to!string);
}

void selectVertices(string indicesJson) {
    auto r = postJson("/api/command", commandBody("mesh.select",
        `{"mode":"vertices","indices":` ~ indicesJson ~ `}`));
    assert(r["status"].str == "ok", "mesh.select failed: " ~ r.toString());
}

struct LinearFit {
    float[3] start;
    float[3] end;
}

LinearFit activateTaper(string selection, float sizeX = 4.0f,
                        float sizeY = 1.0f, float sizeZ = 0.5f,
                        string workplaneMode = "worldY") {
    buildRig(sizeX, sizeY, sizeZ, workplaneMode);
    selectVertices(selection);
    cmd("tool.set xfrm.taper on");
    auto attrs = falloffAttrs();
    return LinearFit(vec3(attrs["start"]), vec3(attrs["end"]));
}

unittest { // cube control: workplane normal and higher-index max axis coincide
    auto fit = activateTaper("[]", 2.0f, 2.0f, 2.0f, "worldZ");
    const float[3] expectedStart = [3.0f, 2.0f, -2.0f];
    const float[3] expectedEnd = [3.0f, 2.0f, 0.0f];
    assert(near(fit.start, expectedStart) && near(fit.end, expectedEnd),
        format("cube control: coincident workplane/max-extent axis should fit Z; "
            ~ "got start=%s end=%s", fit.start, fit.end));
}

unittest { // three distinct extents choose X, not the workplane's Y normal
    auto fit = activateTaper("[]");
    const float[3] expectedStart = [1.0f, 2.0f, -1.0f];
    const float[3] expectedEnd = [5.0f, 2.0f, -1.0f];
    assert(near(fit.start, expectedStart) && near(fit.end, expectedEnd),
        format("three-distinct-extents activation: expected largest X extent, "
            ~ "not workplane Y; got start=%s end=%s", fit.start, fit.end));
}

unittest { // 2 x 2 x 1 tie resolves from X toward the higher Y index
    auto fit = activateTaper("[]", 2.0f, 2.0f, 1.0f, "worldY");
    const float[3] expectedStart = [3.0f, 1.0f, -1.0f];
    const float[3] expectedEnd = [3.0f, 3.0f, -1.0f];
    assert(near(fit.start, expectedStart) && near(fit.end, expectedEnd),
        format("2x2x1 tie: expected higher-index Y extent; got start=%s end=%s",
            fit.start, fit.end));
}

unittest { // one selected vertex yields the same fit as selecting every vertex
    string all = "[";
    foreach (i; 0 .. 42) all ~= (i ? "," : "") ~ i.to!string;
    all ~= "]";
    auto full = activateTaper(all);
    auto one = activateTaper("[0]");
    assert(near(one.start, full.start) && near(one.end, full.end),
        format("single-vertex W2: activation must use the layer bbox, not the "
            ~ "selected vertex; full=(%s -> %s) one=(%s -> %s)",
            full.start, full.end, one.start, one.end));
}

struct PresetCase {
    string id;
    string type;
}

immutable PresetCase[] sizedPresets = [
    PresetCase("xfrm.softMove", "radial"),
    PresetCase("xfrm.softRotate", "radial"),
    PresetCase("xfrm.softScale", "radial"),
    PresetCase("xfrm.softTransform", "radial"),
    PresetCase("xfrm.twist", "linear"),
    PresetCase("xfrm.swirl", "radial"),
    PresetCase("xfrm.shear", "linear"),
    PresetCase("xfrm.taper", "linear"),
    PresetCase("xfrm.bulge", "radial"),
    PresetCase("xfrm.flare", "linear"),
    PresetCase("xfrm.vortex", "cylinder"),
];

unittest { // all and only the 11 size-bearing shipped presets are covered
    assert(sizedPresets.length != 0,
        "falloff auto-fit preset population must not be zero");
    assert(sizedPresets.length == 11,
        format("falloff auto-fit preset population changed: expected 11, got %d",
            sizedPresets.length));

    foreach (preset; sizedPresets) {
        buildRig();
        selectVertices("[]");
        cmd("tool.set " ~ preset.id ~ " on");
        auto attrs = falloffAttrs();
        assert(attrs["type"] == preset.type,
            preset.id ~ ": expected type " ~ preset.type ~ ", got " ~ attrs["type"]);
        if (preset.type == "linear") {
            assert(near(vec3(attrs["start"]), [1.0f, 2.0f, -1.0f]) &&
                   near(vec3(attrs["end"]), [5.0f, 2.0f, -1.0f]),
                preset.id ~ ": linear activation did not fit the layer bbox");
        } else {
            assert(near(vec3(attrs["center"]), [3.0f, 2.0f, -1.0f]) &&
                   near(vec3(attrs["size"]), [2.0f, 0.5f, 0.25f]),
                preset.id ~ ": radial/cylinder activation did not fit the layer bbox");
        }
    }
}

unittest { // an explicitly chosen falloff retains user-authored geometry
    buildRig();
    selectVertices("[]");
    cmd("falloff.linear");
    cmd(`tool.pipe.attr falloff start "9,8,7"`);
    cmd(`tool.pipe.attr falloff end "6,5,4"`);
    cmd("tool.set xfrm.taper on");
    auto attrs = falloffAttrs();
    assert(near(vec3(attrs["start"]), [9.0f, 8.0f, 7.0f]) &&
           near(vec3(attrs["end"]), [6.0f, 5.0f, 4.0f]),
        "userLocked falloff geometry was overwritten by tool activation");
}
