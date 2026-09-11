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

struct LayerBounds {
    float[3] min;
    float[3] max;
    float[3] extent;
    float[3] center;
}

LayerBounds layerBounds(size_t layer) {
    auto verts = getJson(format("/api/model?layer=%d", layer))["vertices"].array;
    assert(verts.length > 0,
        format("degenerate falloff rig layer %d has no vertices", layer));

    LayerBounds b;
    foreach (axis; 0 .. 3) {
        b.min[axis] = cast(float)verts[0].array[axis].floating;
        b.max[axis] = b.min[axis];
    }
    foreach (v; verts) foreach (axis; 0 .. 3) {
        float x = cast(float)v.array[axis].floating;
        if (x < b.min[axis]) b.min[axis] = x;
        if (x > b.max[axis]) b.max[axis] = x;
    }
    foreach (axis; 0 .. 3) {
        b.extent[axis] = b.max[axis] - b.min[axis];
        b.center[axis] = (b.max[axis] + b.min[axis]) * 0.5f;
    }
    return b;
}

void buildDegenerateRig() {
    auto reset = postJson("/api/command",
        commandBody("scene.reset", `{"empty":true}`));
    assert(reset["status"].str == "ok", "scene.reset failed: " ~ reset.toString());
    cmd("select.typeFrom vertex");

    cmd("prim.cube cenX:3 cenY:2 cenZ:-1 sizeX:4 sizeY:4 sizeZ:0 "
        ~ "segmentsX:2 segmentsY:2 segmentsZ:2 radius:0");
    cmd("layer.add name:Segment");
    cmd("prim.cube cenX:3 cenY:2 cenZ:-1 sizeX:4 sizeY:0 sizeZ:0 "
        ~ "segmentsX:2 segmentsY:2 segmentsZ:2 radius:0");
    cmd("layer.add name:Point");
    cmd("prim.cube cenX:3 cenY:2 cenZ:-1 sizeX:0 sizeY:0 sizeZ:0 "
        ~ "segmentsX:2 segmentsY:2 segmentsZ:2 radius:0");

    // Population floor: prove the three authored layers really expose the
    // vanished extents before any falloff writer is exercised.
    auto flat = layerBounds(0);
    auto segment = layerBounds(1);
    auto point = layerBounds(2);
    assert(flat.extent[2] == 0.0f,
        format("flat-layer population: expected zero Z extent, got %s", flat.extent));
    assert(segment.extent[1] == 0.0f && segment.extent[2] == 0.0f,
        format("segment-layer population: expected zero Y/Z extents, got %s",
            segment.extent));
    assert(point.extent == [0.0f, 0.0f, 0.0f],
        format("point-layer population: expected three zero extents, got %s",
            point.extent));
    assert(near(flat.extent, [4.0f, 4.0f, 0.0f]) &&
           near(segment.extent, [4.0f, 0.0f, 0.0f]),
        format("degenerate falloff rig lost its surviving extents: flat=%s segment=%s",
            flat.extent, segment.extent));
    assert(near(flat.center, [3.0f, 2.0f, -1.0f]) &&
           near(segment.center, flat.center) && near(point.center, flat.center),
        format("degenerate falloff rig layers must share center (3,2,-1): %s %s %s",
            flat.center, segment.center, point.center));
}

void selectRigLayer(size_t layer) {
    cmd(format("layer.select index:%d mode:set", layer));
    cmd("select.typeFrom vertex");
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

unittest { // axisless sizing writes every vanished extent as exact zero
    buildDegenerateRig();
    immutable float[3][3] expectedHalf = [
        [2.0f, 2.0f, 0.0f],
        [2.0f, 0.0f, 0.0f],
        [0.0f, 0.0f, 0.0f],
    ];
    foreach (layer; 0 .. expectedHalf.length) {
        selectRigLayer(layer);
        cmd("tool.pipe.attr falloff type radial");
        cmd(`tool.pipe.attr falloff center "9,8,7"`);
        cmd(`tool.pipe.attr falloff size "9,8,7"`);
        cmd("falloff.autosize");
        auto attrs = falloffAttrs();
        assert(near(vec3(attrs["center"]), [3.0f, 2.0f, -1.0f]),
            format("axisless Radial layer %d did not write the common center", layer));
        assert(near(vec3(attrs["size"]), expectedHalf[layer]),
            format("axisless Radial layer %d must write vanished extents as zero: "
                ~ "expected %s, got %s", layer, expectedHalf[layer],
                vec3(attrs["size"])));
    }

    selectRigLayer(2);
    cmd("tool.pipe.attr falloff type linear");
    cmd(`tool.pipe.attr falloff start "9,8,7"`);
    cmd(`tool.pipe.attr falloff end "6,5,4"`);
    cmd("falloff.autosize");
    auto attrs = falloffAttrs();
    assert(near(vec3(attrs["start"]), [3.0f, 2.0f, -1.0f]) &&
           near(vec3(attrs["end"]), [3.0f, 2.0f, -1.0f]),
        format("axisless Linear point layer must write a degenerate pair at the "
            ~ "layer center; got %s -> %s", vec3(attrs["start"]),
            vec3(attrs["end"])));
}

unittest { // per-axis sizing refuses each vanished axis and writes nothing
    buildDegenerateRig();
    struct RefusalCase { size_t layer; string axis; }
    immutable RefusalCase[] cases = [
        RefusalCase(0, "z"),
        RefusalCase(1, "y"), RefusalCase(1, "z"),
        RefusalCase(2, "x"), RefusalCase(2, "y"), RefusalCase(2, "z"),
    ];
    foreach (c; cases) {
        selectRigLayer(c.layer);
        cmd("tool.pipe.attr falloff type linear");
        cmd(`tool.pipe.attr falloff start "9,8,7"`);
        cmd(`tool.pipe.attr falloff end "6,5,4"`);
        auto refused = postJson("/api/command", "falloff.autosize " ~ c.axis);
        assert(refused["status"].str == "error",
            format("degenerate axis action must refuse: layer=%d axis=%s response=%s",
                c.layer, c.axis, refused));
        auto attrs = falloffAttrs();
        assert(near(vec3(attrs["start"]), [9.0f, 8.0f, 7.0f]) &&
               near(vec3(attrs["end"]), [6.0f, 5.0f, 4.0f]),
            format("refused degenerate axis action wrote falloff geometry: "
                ~ "layer=%d axis=%s start=%s end=%s", c.layer, c.axis,
                vec3(attrs["start"]), vec3(attrs["end"])));
    }
}

unittest { // automatic activation has no degenerate-extent guard
    buildDegenerateRig();

    selectRigLayer(0);
    cmd("tool.set xfrm.softMove on");
    auto radial = falloffAttrs();
    assert(near(vec3(radial["center"]), [3.0f, 2.0f, -1.0f]) &&
           near(vec3(radial["size"]), [2.0f, 2.0f, 0.0f]),
        format("automatic Radial flat-layer fit must write the degenerate size; "
            ~ "got center=%s size=%s", vec3(radial["center"]),
            vec3(radial["size"])));

    selectRigLayer(2);
    cmd("tool.set xfrm.taper on");
    auto linear = falloffAttrs();
    assert(near(vec3(linear["start"]), [3.0f, 2.0f, -1.0f]) &&
           near(vec3(linear["end"]), [3.0f, 2.0f, -1.0f]),
        format("automatic Linear point-layer fit must write the degenerate pair; "
            ~ "got %s -> %s", vec3(linear["start"]), vec3(linear["end"])));
}
